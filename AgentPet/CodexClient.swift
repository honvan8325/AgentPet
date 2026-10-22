import AppKit
import Combine
import CoreFoundation
import Darwin
import Foundation

enum JSONValue: Codable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

enum RPCTransportError: LocalizedError {
    case unavailable(String)
    case timeout
    case closed
    case invalidJSON
    case write(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .server(let message), .write(let message): message
        case .timeout: "Codex App Server did not respond in time."
        case .closed: "Codex App Server closed the connection."
        case .invalidJSON: "Codex App Server returned invalid JSON."
        }
    }
}

actor CodexRPC {
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var readerTask: Task<Void, Never>?
    private var buffer = Data()
    private var transportFailed = false
    private var nextID = 1
    private var generation: UInt64 = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var notificationHandler: (@Sendable (Data) -> Void)?
    private var disconnectHandler: (@Sendable () -> Void)?

    func setHandlers(
        notification: @escaping @Sendable (Data) -> Void,
        disconnect: @escaping @Sendable () -> Void
    ) {
        notificationHandler = notification
        disconnectHandler = disconnect
    }

    func start() async throws {
        if process?.isRunning == true && !transportFailed { return }
        if process != nil { await stop() }

        let appURL = await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        }
        let appBundleURL = appURL ?? URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        let executable = appBundleURL.appendingPathComponent(
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        )
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RPCTransportError.unavailable(
                "ChatGPT Desktop is not installed or does not contain an accessible Codex CLI."
            )
        }

        generation &+= 1
        let currentGeneration = generation
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { await self?.processDidExit(generation: currentGeneration) }
        }
        self.process = process
        self.input = input
        self.output = output
        buffer.removeAll(keepingCapacity: true)
        transportFailed = false

        do {
            try process.run()
        } catch {
            self.process = nil
            self.input = nil
            self.output = nil
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            throw RPCTransportError.unavailable(error.localizedDescription)
        }

        let readDescriptor = output.fileHandleForReading.fileDescriptor
        readerTask = Task.detached(priority: .utility) { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 65_536)
            while !Task.isCancelled {
                var descriptor = pollfd(fd: readDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 250)
                if ready < 0 && errno == EINTR { continue }
                if ready < 0 { break }
                if ready == 0 { continue }
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(readDescriptor, buffer.baseAddress, buffer.count)
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                await self?.receive(Data(bytes.prefix(count)), generation: currentGeneration)
            }
            await self?.processDidExit(generation: currentGeneration)
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let params: JSONValue = .object([
            "clientInfo": .object([
                "name": .string("agentpet"),
                "title": .string("AgentPet"),
                "version": .string(version)
            ])
        ])
        let response = try await request("initialize", params: params, timeout: 20)
        try Self.checkServerError(response)
        try sendNotification("initialized", params: .object([:]))
    }

    func request(_ method: String, params: JSONValue, timeout: Double = 15) async throws -> Data {
        guard process?.isRunning == true, !transportFailed, let input else { throw RPCTransportError.closed }
        let id = nextID
        nextID += 1
        let message: [String: JSONValue] = [
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params
        ]
        let encoded = try Self.encodeLine(.object(message))

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(timeout))
                    await self?.timeout(id)
                } catch {}
            }
            do {
                try input.fileHandleForWriting.write(contentsOf: encoded)
            } catch {
                timeouts.removeValue(forKey: id)?.cancel()
                pending.removeValue(forKey: id)?.resume(throwing: RPCTransportError.write(error.localizedDescription))
            }
        }
    }

    func sendNotification(_ method: String, params: JSONValue) throws {
        guard process?.isRunning == true, !transportFailed, let input else { throw RPCTransportError.closed }
        let message: JSONValue = .object([
            "method": .string(method),
            "params": params
        ])
        do {
            try input.fileHandleForWriting.write(contentsOf: Self.encodeLine(message))
        } catch {
            throw RPCTransportError.write(error.localizedDescription)
        }
    }

    func stop() async {
        generation &+= 1
        let oldProcess = process
        let oldInput = input
        let oldOutput = output
        let oldReader = readerTask
        process = nil
        readerTask = nil
        failPending(RPCTransportError.closed)
        oldReader?.cancel()
        try? oldInput?.fileHandleForWriting.close()
        input = nil
        output = nil
        buffer.removeAll(keepingCapacity: false)
        transportFailed = false
        if let oldProcess, oldProcess.isRunning {
            oldProcess.terminate()
            let deadline = ContinuousClock.now + .seconds(2)
            while oldProcess.isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if oldProcess.isRunning {
                _ = Darwin.kill(oldProcess.processIdentifier, SIGKILL)
                let killDeadline = ContinuousClock.now + .seconds(1)
                while oldProcess.isRunning && ContinuousClock.now < killDeadline {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        }
        try? oldOutput?.fileHandleForReading.close()
        if let oldReader { await oldReader.value }
    }

    private func receive(_ data: Data, generation: UInt64) {
        guard generation == self.generation, !transportFailed else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                failTransport(RPCTransportError.invalidJSON)
                return
            }

            if message["id"] != nil {
                guard let number = message["id"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite,
                      number.doubleValue.rounded(.towardZero) == number.doubleValue,
                      let id = Int(exactly: number.int64Value),
                      NSNumber(value: number.int64Value).compare(number) == .orderedSame,
                      let continuation = pending.removeValue(forKey: id) else { continue }
                timeouts.removeValue(forKey: id)?.cancel()
                continuation.resume(returning: line)
            } else if message["method"] != nil {
                notificationHandler?(line)
            }
        }
        if buffer.count > 8_388_608 { failTransport(RPCTransportError.invalidJSON) }
    }

    private func failTransport(_ error: Error) {
        guard !transportFailed else { return }
        transportFailed = true
        buffer.removeAll(keepingCapacity: false)
        failPending(error)
        process?.terminate()
    }

    private func timeout(_ id: Int) {
        timeouts.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(throwing: RPCTransportError.timeout)
    }

    private func processDidExit(generation: UInt64) {
        guard generation == self.generation, process != nil,
              (input != nil || output != nil) else { return }
        let oldProcess = process
        transportFailed = true
        readerTask?.cancel()
        readerTask = nil
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        input = nil
        output = nil
        buffer.removeAll(keepingCapacity: false)
        failPending(RPCTransportError.closed)
        if oldProcess?.isRunning == true { oldProcess?.terminate() }
        disconnectHandler?()
    }

    private func failPending(_ error: Error) {
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private static func encodeLine(_ value: JSONValue) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    private static func checkServerError(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RPCTransportError.invalidJSON
        }
        if let error = object["error"] as? [String: Any] {
            throw RPCTransportError.server(error["message"] as? String ?? "Codex App Server initialization failed.")
        }
    }
}

struct UsageWindow: Identifiable, Hashable {
    let durationMinutes: Int
    let remaining: Double
    let resetAt: Date?

    var id: Int { durationMinutes }
    var label: String {
        switch durationMinutes {
        case 300: "5H"
        case 10080: "7D"
        default: "\(durationMinutes)m"
        }
    }
}

struct UsageSnapshot {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let updatedAt: Date

    var availableWindows: [UsageWindow] {
        [fiveHour, sevenDay].compactMap { $0 }
    }

    var energyWindow: UsageWindow? {
        fiveHour ?? sevenDay
    }
}

enum UsageAvailability: String, Equatable {
    case loading, available, unavailable, disconnected
}

@MainActor
final class CodexClient: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting, connected, reconnecting, disconnected
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var usage: UsageSnapshot?
    @Published private(set) var usageAvailability: UsageAvailability = .disconnected
    @Published private(set) var threads: [CodexThread] = []
    @Published private(set) var errorMessage: String?
    var onUsageUpdate: ((UsageSnapshot?) -> Void)?

    private struct MetadataLookup {
        let id: UUID
        let task: Task<MetadataLookupResult, Never>
    }

    private struct MetadataLookupResult {
        let thread: CodexThread?
        let isConfirmedMiss: Bool
    }

    private let rpc = CodexRPC()
    private var metadataLookups: [String: MetadataLookup] = [:]
    private var metadataMisses: [String: Date] = [:]
    private var metadataRetryAfter: [String: Date] = [:]
    private var preservedThreadIDs = Set<String>()
    private var consecutiveTimeouts = 0
    private var connectionGeneration: UInt64 = 0
    private var usageRevision: UInt64 = 0
    private let pageSize = 50

    func connect(reconnecting: Bool) async throws {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connectionState = reconnecting ? .reconnecting : .connecting
        setUsage(nil)
        for lookup in metadataLookups.values { lookup.task.cancel() }
        metadataLookups.removeAll(keepingCapacity: true)
        metadataMisses.removeAll(keepingCapacity: true)
        metadataRetryAfter.removeAll(keepingCapacity: true)
        await rpc.setHandlers(
            notification: { [weak self] data in
                Task { @MainActor in self?.receiveNotification(data, generation: generation) }
            },
            disconnect: { [weak self] in
                Task { @MainActor in self?.markReconnecting(RPCTransportError.closed, generation: generation) }
            }
        )
        do {
            try await rpc.start()
            guard generation == connectionGeneration else { throw RPCTransportError.closed }
            connectionState = .connected
            usageAvailability = usage == nil ? .loading : .available
            consecutiveTimeouts = 0
            errorMessage = nil
        } catch {
            if generation == connectionGeneration {
                connectionState = .disconnected
                setUsage(nil)
                errorMessage = error.localizedDescription
                await rpc.stop()
            }
            throw error
        }
    }

    func refreshUsage() async {
        guard connectionState == .connected else { return }
        let generation = connectionGeneration
        let revision = usageRevision
        do {
            let data = try await rpc.request("account/rateLimits/read", params: .object([:]))
            guard generation == connectionGeneration, connectionState == .connected else { return }
            guard revision == usageRevision else { return }
            consecutiveTimeouts = 0
            let result = try Self.resultObject(data)
            let bucket = ((result["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any])
                ?? (result["rateLimits"] as? [String: Any])
            guard let bucket else {
                setUsage(nil)
                errorMessage = "Codex usage is unavailable."
                return
            }
            let windows = Self.parseWindows(bucket)
            guard !windows.isEmpty else {
                setUsage(nil)
                errorMessage = "Codex usage is unavailable."
                return
            }
            setUsage(UsageSnapshot(fiveHour: windows[300], sevenDay: windows[10080], updatedAt: Date()))
            errorMessage = nil
        } catch {
            guard generation == connectionGeneration else { return }
            guard revision == usageRevision else { return }
            handleRequestError(error, clearUsage: true)
        }
    }

    func refreshThreads(preserving threadIDs: Set<String> = []) async {
        guard connectionState == .connected else { return }
        let generation = connectionGeneration
        do {
            let page = try await loadThreadPage()
            guard generation == connectionGeneration, connectionState == .connected else { return }
            consecutiveTimeouts = 0
            preservedThreadIDs = threadIDs
            for thread in page {
                metadataMisses.removeValue(forKey: thread.id)
                metadataRetryAfter.removeValue(forKey: thread.id)
            }
            let mapped = threads.filter { threadIDs.contains($0.id) }
            threads = Array(uniqueThreads(page + mapped).prefix(pageSize + mapped.count))
            errorMessage = nil
        } catch {
            guard generation == connectionGeneration else { return }
            errorMessage = error.localizedDescription
            handleRequestError(error)
        }
    }

    private func readThreadMetadata(_ id: String, generation: UInt64) async -> MetadataLookupResult {
        guard generation == connectionGeneration, connectionState == .connected else {
            return MetadataLookupResult(thread: nil, isConfirmedMiss: false)
        }
        let params: JSONValue = .object([
            "threadId": .string(id),
            "includeTurns": .bool(false)
        ])
        do {
            let data = try await rpc.request("thread/read", params: params)
            guard generation == connectionGeneration, connectionState == .connected else {
                return MetadataLookupResult(thread: nil, isConfirmedMiss: false)
            }
            consecutiveTimeouts = 0
            let result = try Self.resultObject(data)
            let row = (result["thread"] as? [String: Any]) ?? result
            guard let metadata = Self.parseThread(row), metadata.id == id else {
                return MetadataLookupResult(thread: nil, isConfirmedMiss: true)
            }
            merge([metadata], preserving: [id])
            return MetadataLookupResult(thread: metadata, isConfirmedMiss: false)
        } catch {
            if generation == connectionGeneration { handleRequestError(error) }
            return MetadataLookupResult(thread: nil, isConfirmedMiss: false)
        }
    }

    func findThreadMetadata(_ id: String) async -> CodexThread? {
        guard connectionState == .connected else { return nil }
        let generation = connectionGeneration
        if let cached = threads.first(where: { $0.id == id }) { return cached }
        if let lookup = metadataLookups[id] {
            let thread = await lookup.task.value.thread
            return generation == connectionGeneration ? thread : nil
        }
        if let miss = metadataMisses[id], Date().timeIntervalSince(miss) < 30 { return nil }
        if let retryAfter = metadataRetryAfter[id], retryAfter > Date() { return nil }
        let lookupID = UUID()
        let task = Task<MetadataLookupResult, Never> { [weak self] in
            guard let self else { return MetadataLookupResult(thread: nil, isConfirmedMiss: false) }
            return await self.readThreadMetadata(id, generation: generation)
        }
        metadataLookups[id] = MetadataLookup(id: lookupID, task: task)
        let result = await task.value
        guard generation == connectionGeneration else { return nil }
        if metadataLookups[id]?.id == lookupID {
            metadataLookups.removeValue(forKey: id)
            if result.isConfirmedMiss {
                metadataMisses[id] = Date()
                metadataRetryAfter.removeValue(forKey: id)
                if metadataMisses.count > 200,
                   let oldest = metadataMisses.min(by: { $0.value < $1.value })?.key {
                    metadataMisses.removeValue(forKey: oldest)
                }
            } else if result.thread == nil {
                metadataRetryAfter[id] = Date().addingTimeInterval(2)
                metadataMisses.removeValue(forKey: id)
                if metadataRetryAfter.count > 200,
                   let oldest = metadataRetryAfter.min(by: { $0.value < $1.value })?.key {
                    metadataRetryAfter.removeValue(forKey: oldest)
                }
            } else {
                metadataRetryAfter.removeValue(forKey: id)
                metadataMisses.removeValue(forKey: id)
            }
        }
        return result.thread
    }

    func prepareReconnect() async {
        connectionGeneration &+= 1
        setUsage(nil)
        for lookup in metadataLookups.values { lookup.task.cancel() }
        metadataLookups.removeAll(keepingCapacity: true)
        metadataMisses.removeAll(keepingCapacity: true)
        metadataRetryAfter.removeAll(keepingCapacity: true)
        preservedThreadIDs.removeAll(keepingCapacity: true)
        threads.removeAll(keepingCapacity: true)
        await rpc.stop()
        connectionState = .reconnecting
        usageAvailability = .loading
    }

    func shutdown() async {
        connectionGeneration &+= 1
        setUsage(nil)
        connectionState = .disconnected
        usageAvailability = .disconnected
        await rpc.stop()
    }

    func markReconnecting(_ error: Error, generation expectedGeneration: UInt64? = nil) {
        guard expectedGeneration == nil || expectedGeneration == connectionGeneration,
              connectionState != .disconnected else { return }
        connectionGeneration &+= 1
        setUsage(nil)
        connectionState = .reconnecting
        usageAvailability = .loading
        errorMessage = error.localizedDescription
    }

    private func handleRequestError(_ error: Error, clearUsage: Bool = false) {
        errorMessage = error.localizedDescription
        var shouldClearUsage = clearUsage
        guard let transportError = error as? RPCTransportError else {
            if shouldClearUsage { setUsage(nil) }
            return
        }
        switch transportError {
        case .timeout:
            consecutiveTimeouts += 1
            if consecutiveTimeouts >= 2 {
                shouldClearUsage = true
                connectionState = .reconnecting
                usageAvailability = .loading
            }
        case .closed, .invalidJSON, .write:
            consecutiveTimeouts = 0
            shouldClearUsage = true
            connectionState = .reconnecting
            usageAvailability = .loading
        case .unavailable, .server:
            consecutiveTimeouts = 0
        }
        if shouldClearUsage { setUsage(nil) }
    }

    private func merge(_ additions: [CodexThread], preserving extraIDs: Set<String> = []) {
        for thread in additions {
            if let index = threads.firstIndex(where: { $0.id == thread.id }) {
                threads[index] = thread
            } else {
                threads.append(thread)
            }
        }
        let recent = threads.sorted {
            ($0.updatedAt ?? $0.createdAt ?? .distantPast) > ($1.updatedAt ?? $1.createdAt ?? .distantPast)
        }.prefix(pageSize)
        let mapped = threads.filter { preservedThreadIDs.contains($0.id) || extraIDs.contains($0.id) }
        threads = Array(uniqueThreads(Array(recent) + mapped))
    }

    private func uniqueThreads(_ values: [CodexThread]) -> [CodexThread] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private func loadThreadPage() async throws -> [CodexThread] {
        let values: [String: JSONValue] = [
            "limit": .number(Double(pageSize)),
            "sourceKinds": .array([.string("vscode"), .string("appServer"), .string("cli")]),
            "useStateDbOnly": .bool(true)
        ]
        let data = try await rpc.request("thread/list", params: .object(values))
        let result = try Self.resultObject(data)
        guard let rows = result["data"] as? [[String: Any]] else {
            throw RPCTransportError.server("Codex App Server returned thread/list without result.data.")
        }
        return rows.compactMap(Self.parseThread)
    }

    private func receiveNotification(_ data: Data, generation: UInt64) {
        guard generation == connectionGeneration, connectionState == .connected else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "account/rateLimits/updated" else { return }
        guard let params = object["params"] as? [String: Any] else {
            setUsage(nil)
            return
        }
        let bucket = ((params["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any])
            ?? (params["rateLimits"] as? [String: Any])
        guard let bucket else {
            setUsage(nil)
            return
        }
        let windows = Self.parseWindows(bucket)
        guard !windows.isEmpty else {
            setUsage(nil)
            return
        }
        setUsage(UsageSnapshot(fiveHour: windows[300], sevenDay: windows[10080], updatedAt: Date()))
    }

    private func setUsage(_ snapshot: UsageSnapshot?) {
        usageRevision &+= 1
        usage = snapshot
        if snapshot != nil {
            usageAvailability = .available
        } else {
            switch connectionState {
            case .connected: usageAvailability = .unavailable
            case .disconnected: usageAvailability = .disconnected
            case .connecting, .reconnecting: usageAvailability = .loading
            }
        }
        onUsageUpdate?(snapshot)
    }

    private static func resultObject(_ data: Data) throws -> [String: Any] {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RPCTransportError.invalidJSON
        }
        if let error = response["error"] as? [String: Any] {
            throw RPCTransportError.server(error["message"] as? String ?? "Codex App Server request failed.")
        }
        guard let result = response["result"] as? [String: Any] else {
            throw RPCTransportError.server("Codex App Server response did not contain a result.")
        }
        return result
    }

    private static func parseWindows(_ bucket: [String: Any]) -> [Int: UsageWindow] {
        var windows: [Int: UsageWindow] = [:]
        for key in ["primary", "secondary"] {
            guard let window = bucket[key] as? [String: Any],
                  let usedValue = window["usedPercent"] as? NSNumber,
                  CFGetTypeID(usedValue) != CFBooleanGetTypeID(),
                  usedValue.doubleValue.isFinite,
                  let durationValue = window["windowDurationMins"] as? NSNumber,
                  CFGetTypeID(durationValue) != CFBooleanGetTypeID(),
                  durationValue.doubleValue.isFinite,
                  durationValue.doubleValue.rounded(.towardZero) == durationValue.doubleValue else { continue }
            let duration = durationValue.intValue
            guard durationValue.doubleValue == Double(duration),
                  duration == 300 || duration == 10080 else { continue }
            let used = min(100, max(0, usedValue.doubleValue))
            windows[duration] = UsageWindow(
                durationMinutes: duration,
                remaining: 100 - used,
                resetAt: parseDate(window["resetsAt"])
            )
        }
        return windows
    }

    private static func parseThread(_ row: [String: Any]) -> CodexThread? {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        return CodexThread(
            id: id,
            title: (row["name"] as? String) ?? (row["title"] as? String) ?? "Untitled thread",
            source: row["source"] as? String,
            createdAt: parseDate(row["createdAt"]),
            updatedAt: parseDate(row["updatedAt"])
        )
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = value as? String {
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }
}
