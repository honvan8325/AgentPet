import Combine
import Darwin
import Foundation

enum HookIntegrationState: Equatable {
    case disabled
    case configured
    case receivingEvents
    case error

    var title: String {
        switch self {
        case .disabled: "Live tracking is disabled"
        case .configured: "Configured; no lifecycle event observed yet"
        case .receivingEvents: "Receiving lifecycle events"
        case .error: "Integration needs attention"
        }
    }
}

@MainActor
final class HookIntegration: ObservableObject {
    @Published private(set) var state: HookIntegrationState = .disabled
    @Published private(set) var errorMessage: String?
    @Published private(set) var configuredHandlerCount = 0
    @Published private(set) var nativeHandlerCount = 0
    @Published private(set) var needsMigration = false

    var hasConfiguredHandlers: Bool { configuredHandlerCount > 0 }
    var isPartiallyConfigured: Bool { configuredHandlerCount > 0 && configuredHandlerCount < eventNames.count }
    var hasCompleteNativeHandlers: Bool { nativeHandlerCount == eventNames.count }
    var needsRepair: Bool { isPartiallyConfigured || needsMigration || (state == .error && !hasCompleteNativeHandlers) }
    var canRetryTracking: Bool { state == .error && hasCompleteNativeHandlers && !needsMigration }

    private let fileManager = FileManager.default
    private let eventNames = ["UserPromptSubmit", "Stop", "PermissionRequest", "Interrupt"]
    private var timer: Timer?
    private var offset: UInt64 = 0
    private var fileIdentity: UInt64?
    private var lastSequence: UInt64?
    private var partialLine = Data()
    private var onEvent: (@MainActor (SessionEvent) -> Void)?
    private var onTrackingUnavailable: (@MainActor () -> Void)?
    private var hooksConfigSnapshot: Data?

    private var supportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentPet", isDirectory: true)
    }

    private var collectorURL: URL {
        supportDirectory.appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("AgentPetHook")
    }
    private var legacyCollectorURL: URL { supportDirectory.appendingPathComponent("hook.py") }
    private var bundledCollectorURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AgentPetHook")
    }
    private var eventsURL: URL { supportDirectory.appendingPathComponent("events.jsonl") }
    private var eventsLockURL: URL { supportDirectory.appendingPathComponent("events.lock") }
    private var eventsGapURL: URL { supportDirectory.appendingPathComponent("events.gap") }
    private var hooksURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    func start(
        onEvent: @escaping @MainActor (SessionEvent) -> Void,
        onTrackingUnavailable: @escaping @MainActor () -> Void
    ) {
        self.onEvent = onEvent
        self.onTrackingUnavailable = onTrackingUnavailable
        do {
            try installBundledCollector()
            let coverage = try handlerCoverage()
            configuredHandlerCount = coverage.configuredCount
            nativeHandlerCount = coverage.nativeCount
            needsMigration = coverage.needsMigration
            if hasCompleteNativeHandlers && !needsMigration {
                errorMessage = nil
                state = .configured
                startReadingAtEnd()
            } else if hasConfiguredHandlers {
                let message = needsMigration
                    ? "Legacy AgentPet hook commands need migration to the native collector."
                    : "Only some AgentPet lifecycle handlers are configured. Repair integration to restore the complete set."
                setError(IntegrationError.invalid(message))
            } else {
                state = .disabled
                errorMessage = nil
                onTrackingUnavailable()
            }
        } catch {
            setError(error)
        }
    }

    func enable() throws {
        var root = try readHooksConfig()
        var hooks = try hooksDictionary(from: root)
        _ = try removeAgentPetHandlers(from: &hooks)
        let command = Self.hookCommand(collector: collectorURL.path)

        for event in eventNames {
            var groups = try hookGroups(for: event, in: hooks)
            groups.append([
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "async": true,
                    "timeout": 3
                ]]
            ])
            hooks[event] = groups
        }
        root["hooks"] = hooks

        try installBundledCollector()
        try writeHooksConfig(root)

        errorMessage = nil
        configuredHandlerCount = eventNames.count
        nativeHandlerCount = eventNames.count
        needsMigration = false
        state = .configured
        startReadingAtEnd()
    }

    func disable() throws {
        var root = try readHooksConfig()
        var hooks = try hooksDictionary(from: root)
        let changed = try removeAgentPetHandlers(from: &hooks)
        guard changed else {
            configuredHandlerCount = 0
            nativeHandlerCount = 0
            needsMigration = false
            state = .disabled
            errorMessage = nil
            stopReading()
            return
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") }
        else { root["hooks"] = hooks }
        try writeHooksConfig(root)
        configuredHandlerCount = 0
        nativeHandlerCount = 0
        needsMigration = false
        state = .disabled
        errorMessage = nil
        stopReading()
    }

    func stop() {
        stopReading()
        onEvent = nil
        onTrackingUnavailable = nil
    }

    func retryTracking() {
        guard hasCompleteNativeHandlers, !needsMigration else { return }
        errorMessage = nil
        state = .configured
        startReadingAtEnd()
    }

    private func startReadingAtEnd() {
        stopReading()
        let lockDescriptor = open(eventsLockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard lockDescriptor >= 0 else {
            setError(POSIXError(.init(rawValue: errno) ?? .EIO))
            return
        }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(lockDescriptor)
            setError(error)
            return
        }
        var continuityLost = fileManager.fileExists(atPath: eventsGapURL.path)
        var sequenceBytes = [UInt8](repeating: 0, count: 32)
        let sequenceLength = sequenceBytes.withUnsafeMutableBytes { rawBuffer in
            Darwin.pread(lockDescriptor, rawBuffer.baseAddress, rawBuffer.count, 0)
        }
        if sequenceLength < 0 {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
            setError(error)
            return
        }
        if sequenceLength > 0 {
            if let text = String(bytes: sequenceBytes.prefix(sequenceLength), encoding: .ascii),
               let sequence = UInt64(text) {
                lastSequence = sequence
            } else {
                continuityLost = true
            }
        }
        let descriptor = open(eventsURL.path, O_RDONLY)
        if descriptor < 0 && errno != ENOENT {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
            setError(error)
            return
        }
        if descriptor >= 0 {
            guard flock(descriptor, LOCK_EX) == 0 else {
                let error = POSIXError(.init(rawValue: errno) ?? .EIO)
                close(descriptor)
                flock(lockDescriptor, LOCK_UN)
                close(lockDescriptor)
                setError(error)
                return
            }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                let error = POSIXError(.init(rawValue: errno) ?? .EIO)
                flock(descriptor, LOCK_UN)
                flock(lockDescriptor, LOCK_UN)
                close(descriptor)
                close(lockDescriptor)
                setError(error)
                return
            }
            offset = UInt64(max(0, metadata.st_size))
            if offset > 0 && lastSequence == nil { continuityLost = true }
            fileIdentity = UInt64(metadata.st_ino)
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        if continuityLost { unlink(eventsGapURL.path) }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        partialLine.removeAll(keepingCapacity: true)
        if continuityLost { onTrackingUnavailable?() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readNewEvents() }
        }
    }

    private func stopReading() {
        timer?.invalidate()
        timer = nil
        offset = 0
        fileIdentity = nil
        lastSequence = nil
        partialLine.removeAll(keepingCapacity: false)
    }

    private func readNewEvents() {
        do {
            let lockDescriptor = open(eventsLockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
            guard lockDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer {
                flock(lockDescriptor, LOCK_UN)
                close(lockDescriptor)
            }
            guard flock(lockDescriptor, LOCK_EX) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }

            let descriptor = open(eventsURL.path, O_CREAT | O_RDWR, mode_t(0o600))
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            guard flock(descriptor, LOCK_EX) == 0 else {
                let error = POSIXError(.init(rawValue: errno) ?? .EIO)
                close(descriptor)
                throw error
            }
            defer {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }

            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            var continuityLost = fileManager.fileExists(atPath: eventsGapURL.path)
            if continuityLost {
                unlink(eventsGapURL.path)
                offset = 0
                lastSequence = nil
                partialLine.removeAll(keepingCapacity: true)
            }
            let identity = UInt64(metadata.st_ino)
            let size = UInt64(max(0, metadata.st_size))
            if size < offset || (fileIdentity != nil && identity != fileIdentity) {
                continuityLost = true
                offset = 0
                lastSequence = nil
                partialLine.removeAll(keepingCapacity: true)
            }
            fileIdentity = identity
            guard lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            let remaining = Int(min(size - min(size, offset), 1_000_000))
            var bytes = [UInt8](repeating: 0, count: remaining)
            var bytesRead = 0
            while bytesRead < remaining {
                let result = bytes.withUnsafeMutableBytes { rawBuffer in
                    Darwin.read(descriptor, rawBuffer.baseAddress!.advanced(by: bytesRead), remaining - bytesRead)
                }
                if result < 0 && errno == EINTR { continue }
                if result < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                if result == 0 { break }
                bytesRead += result
            }
            offset += UInt64(bytesRead)
            var combined = partialLine
            combined.append(contentsOf: bytes.prefix(bytesRead))
            var completeLines: [Data] = []
            var lineStart = combined.startIndex
            while lineStart < combined.endIndex,
                  let newline = combined[lineStart...].firstIndex(of: 0x0A) {
                completeLines.append(Data(combined[lineStart..<newline]))
                lineStart = combined.index(after: newline)
            }
            partialLine = Data(combined[lineStart..<combined.endIndex])
            if partialLine.isEmpty && offset == size {
                guard ftruncate(descriptor, 0) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                offset = 0
            }
            flock(lockDescriptor, LOCK_UN)
            flock(descriptor, LOCK_UN)

            var sequenceCursor = lastSequence
            var decodedEvents: [SessionEvent] = []
            for line in completeLines {
                guard let event = try? JSONDecoder().decode(SessionEvent.self, from: line),
                      event.timestamp.isFinite else {
                    continuityLost = true
                    continue
                }
                guard let sequence = event.sequence else {
                    continuityLost = true
                    sequenceCursor = nil
                    continue
                }
                if let previousSequence = sequenceCursor,
                   sequence != previousSequence &+ 1 {
                    continuityLost = true
                    sequenceCursor = sequence
                    continue
                }
                sequenceCursor = sequence
                guard let sessionID = event.sessionID, !sessionID.isEmpty,
                      let turnID = event.turnID, !turnID.isEmpty else {
                    continuityLost = true
                    continue
                }
                decodedEvents.append(event)
            }
            lastSequence = sequenceCursor
            if continuityLost { onTrackingUnavailable?() }
            for event in decodedEvents {
                state = .receivingEvents
                onEvent?(event)
            }
        } catch {
            setError(error)
        }
    }

    private func handlerCoverage() throws -> (nativeCount: Int, configuredCount: Int, needsMigration: Bool) {
        let root = try readHooksConfig()
        let hooks = try hooksDictionary(from: root)
        var nativeCount = 0
        var configuredCount = 0
        var needsMigration = false
        for event in eventNames {
            var hasNative = false
            var hasAgentPetHandler = false
            for group in try hookGroups(for: event, in: hooks) {
                for handler in group["hooks"] as? [[String: Any]] ?? [] {
                    guard let command = handler["command"] as? String else { continue }
                    if command == Self.hookCommand(collector: collectorURL.path) {
                        hasNative = true
                        hasAgentPetHandler = true
                    } else if command == Self.legacyHookCommand(collector: legacyCollectorURL.path) {
                        needsMigration = true
                        hasAgentPetHandler = true
                    }
                }
            }
            if hasNative { nativeCount += 1 }
            if hasAgentPetHandler { configuredCount += 1 }
        }
        return (nativeCount, configuredCount, needsMigration)
    }

    private func readHooksConfig() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: hooksURL.path) else {
            hooksConfigSnapshot = nil
            return [:]
        }
        let data = try Data(contentsOf: hooksURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntegrationError.invalid("~/.codex/hooks.json must contain a JSON object; it was left unchanged.")
        }
        hooksConfigSnapshot = data
        return root
    }

    private func hooksDictionary(from root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw IntegrationError.invalid("The hooks key in ~/.codex/hooks.json is not an object; it was left unchanged.")
        }
        return hooks
    }

    private func hookGroups(for event: String, in hooks: [String: Any]) throws -> [[String: Any]] {
        guard let value = hooks[event] else { return [] }
        guard let rawGroups = value as? [Any] else {
            throw IntegrationError.invalid("The \(event) hook list is malformed; ~/.codex/hooks.json was left unchanged.")
        }
        return try rawGroups.map { rawGroup in
            guard let group = rawGroup as? [String: Any],
                  group["hooks"] is [Any] else {
                throw IntegrationError.invalid("A \(event) hook group is malformed; ~/.codex/hooks.json was left unchanged.")
            }
            return group
        }
    }

    @discardableResult
    private func removeAgentPetHandlers(from hooks: inout [String: Any]) throws -> Bool {
        var changed = false
        let commands = [
            Self.hookCommand(collector: collectorURL.path),
            Self.legacyHookCommand(collector: legacyCollectorURL.path)
        ]
        for event in eventNames {
            let groups = try hookGroups(for: event, in: hooks)
            var remainingGroups: [[String: Any]] = []
            for var group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    throw IntegrationError.invalid("A \(event) hook group is malformed; ~/.codex/hooks.json was left unchanged.")
                }
                let remaining = handlers.filter { handler in
                    guard let command = handler["command"] as? String else { return true }
                    return !commands.contains(command)
                }
                if remaining.count != handlers.count {
                    changed = true
                    if remaining.isEmpty { continue }
                    group["hooks"] = remaining
                }
                remainingGroups.append(group)
            }
            if remainingGroups.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = remainingGroups }
        }
        return changed
    }

    private func writeHooksConfig(_ root: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw IntegrationError.invalid("The updated Codex hooks configuration is not valid JSON.")
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard try currentHooksConfigData() == hooksConfigSnapshot else {
            throw IntegrationError.invalid("~/.codex/hooks.json changed while AgentPet was preparing an update; the external changes were left untouched.")
        }
        let existed = fileManager.fileExists(atPath: hooksURL.path)
        let oldMode = existed
            ? ((try? fileManager.attributesOfItem(atPath: hooksURL.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600)
            : 0o600
        try fileManager.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporaryURL = hooksURL.deletingLastPathComponent()
            .appendingPathComponent(".hooks.json.agentpet-\(UUID().uuidString)")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(oldMode))
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var writeError: Error?
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var remaining = bytes.count
            var pointer = base
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count <= 0 {
                    writeError = POSIXError(.init(rawValue: errno) ?? .EIO)
                    return
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        if writeError == nil && fsync(descriptor) != 0 { writeError = POSIXError(.init(rawValue: errno) ?? .EIO) }
        close(descriptor)
        if let writeError {
            unlink(temporaryURL.path)
            throw writeError
        }
        let latestConfig: Data?
        do {
            latestConfig = try currentHooksConfigData()
        } catch {
            unlink(temporaryURL.path)
            throw error
        }
        guard latestConfig == hooksConfigSnapshot else {
            unlink(temporaryURL.path)
            throw IntegrationError.invalid("~/.codex/hooks.json changed while AgentPet was preparing an update; the external changes were left untouched.")
        }
        guard rename(temporaryURL.path, hooksURL.path) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            unlink(temporaryURL.path)
            throw error
        }
        hooksConfigSnapshot = data
    }

    private func currentHooksConfigData() throws -> Data? {
        guard fileManager.fileExists(atPath: hooksURL.path) else { return nil }
        return try Data(contentsOf: hooksURL)
    }

    private func installBundledCollector() throws {
        guard fileManager.isExecutableFile(atPath: bundledCollectorURL.path) else {
            throw IntegrationError.invalid("AgentPet's lifecycle collector is missing from the app bundle.")
        }
        let data = try Data(contentsOf: bundledCollectorURL)
        try fileManager.createDirectory(
            at: collectorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if (try? Data(contentsOf: collectorURL)) != data {
            try data.write(to: collectorURL, options: .atomic)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: collectorURL.path)
    }

    private func setError(_ error: Error) {
        stopReading()
        errorMessage = error.localizedDescription
        state = .error
        onTrackingUnavailable?()
    }

    private static func hookCommand(collector: String) -> String {
        shellQuote(collector)
    }

    private static func legacyHookCommand(collector: String) -> String {
        "\(shellQuote("/usr/bin/python3")) \(shellQuote(collector))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum IntegrationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}
