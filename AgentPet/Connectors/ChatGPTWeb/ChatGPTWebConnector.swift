import AppKit
import Combine
import Foundation

enum ChatGPTWebTabActivity: String, Codable, Hashable {
    case unknown, idle, generating
}

enum ChatGPTWebConnectionState: Equatable {
    case disabled, waitingForExtension, connected, disconnected, error

    var title: String {
        switch self {
        case .disabled: "Disabled"
        case .waitingForExtension: "Waiting for extension"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .error: "Setup required"
        }
    }
}

struct ChatGPTWebTab: Identifiable, Equatable {
    let tabID: Int
    var state: ChatGPTWebTabActivity
    var generationID: String?
    var title: String?
    var lastSeen: Date
    var generationStartedAt: Date?
    var id: Int { tabID }
}

@MainActor
final class ChatGPTWebConnector: ObservableObject {
    @Published private(set) var connectionState: ChatGPTWebConnectionState = .disabled
    @Published private(set) var tabs: [Int: ChatGPTWebTab] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var extensionID = ""
    @Published private(set) var isEnabled = false
    @Published private(set) var installationMessage: String?

    var onEnabledChange: (() -> Void)?
    var onShowDashboard: (() -> Void)?
    var onGenerationEnded: ((Int, String, String?, TimeInterval?) -> Void)?

    private let server = ChatGPTWebNativeServer()
    private var freshnessTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var activeConnection: UInt64?
    private var retiredConnection: UInt64 = 0
    private var lastMessageAt: Date?
    private var endedGenerations = Set<String>()
    private var endedOrder: [String] = []
    private let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")

    var generatingTabs: [ChatGPTWebTab] {
        guard isEnabled, connectionState == .connected else { return [] }

        let now = Date.now
        return tabs.values
            .filter { $0.state == .generating && now.timeIntervalSince($0.lastSeen) < 60 }
            .sorted { $0.tabID < $1.tabID }
    }

    var generatingCount: Int {
        generatingTabs.count
    }

    var sortedTabs: [ChatGPTWebTab] {
        let priority: [ChatGPTWebTabActivity: Int] = [
            .generating: 0,
            .idle: 1,
            .unknown: 2
        ]

        return tabs.values.sorted { lhs, rhs in
            let left = priority[lhs.state] ?? 3
            let right = priority[rhs.state] ?? 3

            return left == right ? lhs.tabID < rhs.tabID : left < right
        }
    }

    private var hostURL: URL {
        support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/com.agentpet.chatgpt.json")
    }

    private var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AgentPetWebBridge")
    }

    func start() {
        stop()
        let wasEnabled = isEnabled
        isEnabled = UserDefaults.standard.bool(forKey: "chatGPTWebEnabled")
        extensionID = UserDefaults.standard.string(forKey: "chatGPTWebExtensionID") ?? ""
        if wasEnabled != isEnabled { onEnabledChange?() }
        guard isEnabled else { connectionState = .disabled; return }
        lastError = nil
        do {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil else {
                throw setupError("Google Chrome is not installed. Install Chrome to use ChatGPT Web.")
            }
            try registerNativeHost()
            let currentRevision = revision
            try server.start(
                onMessage: { [weak self] connection, data in
                    Task { @MainActor [weak self] in
                        guard let self, revision == currentRevision, isEnabled else { return }
                        receive(data, connection: connection)
                    }
                },
                onDisconnect: { [weak self] connection in
                    Task { @MainActor [weak self] in
                        guard let self, revision == currentRevision, isEnabled else { return }
                        retiredConnection = max(retiredConnection, connection)
                        if activeConnection == nil || activeConnection == connection {
                            activeConnection = nil
                            tabs.removeAll()
                            connectionState = .disconnected
                        }
                    }
                }
            )
            connectionState = .waitingForExtension
            freshnessTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self, revision == currentRevision, isEnabled else { return }
                    expireStaleObservations()
                }
            }
        } catch {
            connectionState = .error
            lastError = error.localizedDescription
        }
    }

    func stop() {
        revision &+= 1
        freshnessTask?.cancel()
        freshnessTask = nil
        server.stop()
        if let activeConnection { retiredConnection = max(retiredConnection, activeConnection) }
        activeConnection = nil
        lastMessageAt = nil
        tabs.removeAll()
        connectionState = isEnabled ? .disconnected : .disabled
    }

    func enable(extensionID: String) {
        guard validExtensionID(extensionID) else {
            lastError = "Paste the Chrome extension ID: 32 lowercase letters from a to p."
            return
        }
        UserDefaults.standard.set(extensionID, forKey: "chatGPTWebExtensionID")
        UserDefaults.standard.set(true, forKey: "chatGPTWebEnabled")
        start()
    }

    func disable() {
        let wasEnabled = isEnabled
        UserDefaults.standard.set(false, forKey: "chatGPTWebEnabled")
        stop()
        isEnabled = false
        connectionState = .disabled
        lastError = nil
        if wasEnabled { onEnabledChange?() }
        do {
            if let data = try? Data(contentsOf: hostURL),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               value["name"] as? String == "com.agentpet.chatgpt",
               value["allowed_origins"] as? [String] == ["chrome-extension://\(extensionID)/"],
               let path = value["path"] as? String,
               URL(fileURLWithPath: path).lastPathComponent == "AgentPetWebBridge" {
                try FileManager.default.removeItem(at: hostURL)
            }
        } catch { lastError = "Could not remove AgentPet's native host registration: \(error.localizedDescription)" }
    }

    func installOrUpdateExtension() throws {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension/ChatGPTWeb"),
              let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            throw setupError("Google Chrome or the bundled ChatGPT extension is unavailable.")
        }
        let destination = support.appendingPathComponent("AgentPet/ChatGPTExtension")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for name in ["manifest.json", "content.js", "background.js"] {
            let data = try Data(contentsOf: source.appendingPathComponent(name))
            guard !data.isEmpty else { throw setupError("The bundled extension is incomplete. Reinstall AgentPet.") }
            try data.write(to: destination.appendingPathComponent(name), options: .atomic)
        }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        NSWorkspace.shared.open([URL(string: "chrome://extensions")!], withApplicationAt: chrome,
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        installationMessage = "Load this folder unpacked in Chrome. After an update, click Reload on the extension."
    }

    func registerNativeHost() throws {
        guard validExtensionID(extensionID) else {
            throw setupError("Install the extension, paste its ID, then click Connect / Repair.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: helperURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw setupError("AgentPetWebBridge is missing or not executable. Reinstall the complete AgentPet app.")
        }
        let value: [String: Any] = [
            "name": "com.agentpet.chatgpt",
            "description": "AgentPet ChatGPT Web Connector",
            "path": helperURL.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"]
        ]
        try FileManager.default.createDirectory(at: hostURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: hostURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostURL.path)
    }

    func openTab(_ tabID: Int) {
        guard isEnabled, connectionState == .connected, tabs[tabID] != nil else { return }
        server.openTab(tabID)
    }

    func openActiveChatGPT() {
        guard isEnabled, connectionState == .connected else { return }
        let generating = generatingTabs
        if generating.count == 1 { openTab(generating[0].tabID) }
        else if generating.count > 1 { onShowDashboard?() }
    }

    func openChatGPT() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            lastError = "Google Chrome is not installed."
            return
        }
        NSWorkspace.shared.open([URL(string: "https://chatgpt.com/")!], withApplicationAt: chrome,
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private func validExtensionID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.range(of: "^[a-p]{32}$", options: .regularExpression) != nil
    }

    private struct Observation: Decodable {
        let tabId: Int
        let state: ChatGPTWebTabActivity
        let generationId: String?
        let observedAt: Double
        let title: String?
        let generationStartedAt: Double?
    }

    private struct Message: Decodable {
        let version: Int
        let type: String
        let source: String?
        let tabs: [Observation]?
        let tabId: Int?
        let state: ChatGPTWebTabActivity?
        let generationId: String?
        let observedAt: Double?
        let title: String?
        let generationStartedAt: Double?
    }

    private func safeTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }

        let sanitized = raw
            .replacingOccurrences(
                of: "[\\p{Cc}\\p{Cf}]+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty else { return nil }

        return String(sanitized.prefix(120))
    }

    private func receive(_ data: Data, connection: UInt64) {
        guard connection > retiredConnection, connection >= (activeConnection ?? connection), data.count <= 65_536,
              let message = try? JSONDecoder().decode(Message.self, from: data), message.version == 1 else { return }
        let now = Date.now
        switch message.type {
        case "hello":
            guard message.source == "chatgpt_web" else { return }
            activeConnection = connection
            tabs.removeAll()
            connectionState = .connected
            lastError = nil
        case "snapshot":
            guard let observations = message.tabs else { return }
            var snapshot: [Int: ChatGPTWebTab] = [:]
            for observation in observations {
                guard validObservation(observation), snapshot[observation.tabId] == nil else { return }
                snapshot[observation.tabId] = ChatGPTWebTab(tabID: observation.tabId, state: observation.state,
                                                          generationID: observation.generationId,
                                                          title: safeTitle(observation.title), lastSeen: now,
                                                          generationStartedAt: observation.state == .generating
                                                            ? validGenerationStart(observation.generationStartedAt)
                                                            : nil)
            }
            activeConnection = connection
            tabs = snapshot
            connectionState = .connected
            lastError = nil
        case "tab_state":
            guard activeConnection == connection, connectionState == .connected,
                  let id = message.tabId, let state = message.state, let timestamp = message.observedAt else { return }
            let observation = Observation(tabId: id, state: state, generationId: message.generationId,
                                          observedAt: timestamp, title: message.title,
                                          generationStartedAt: message.generationStartedAt)
            guard validObservation(observation) else { return }
            let existing = tabs[id]
            let retainedTitle = state == .unknown ? nil : existing.flatMap {
                $0.state != .unknown && now.timeIntervalSince($0.lastSeen) < 60 ? $0.title : nil
            }
            let title = safeTitle(message.title) ?? retainedTitle
            let generationStartedAt: Date?
            if state == .generating {
                generationStartedAt = validGenerationStart(message.generationStartedAt)
                    ?? (existing?.state == .generating && existing?.generationID == message.generationId
                        ? existing?.generationStartedAt
                        : nil)
            } else {
                generationStartedAt = nil
            }
            tabs[id] = ChatGPTWebTab(tabID: id, state: state, generationID: message.generationId,
                                     title: title, lastSeen: now,
                                     generationStartedAt: generationStartedAt)
        case "tab_title":
            guard activeConnection == connection, connectionState == .connected,
                  let id = message.tabId, var tab = tabs[id] else { return }
            tab.title = safeTitle(message.title)
            tabs[id] = tab
        case "tab_closed":
            guard activeConnection == connection, let id = message.tabId, id >= 0, id <= Int(Int32.max) else { return }
            tabs.removeValue(forKey: id)
        case "generation_ended":
            guard activeConnection == connection, connectionState == .connected,
                  let id = message.tabId, let generation = message.generationId,
                  validGeneration(generation), let timestamp = message.observedAt, validTimestamp(timestamp),
                  let tab = tabs[id], (tab.state == .generating || tab.state == .idle), tab.generationID == generation,
                  now.timeIntervalSince(tab.lastSeen) < 60 else { return }
            let key = "\(id):\(generation)"
            guard endedGenerations.insert(key).inserted else { return }
            endedOrder.append(key)
            if endedOrder.count > 256 { endedGenerations.remove(endedOrder.removeFirst()) }
            let elapsedSeconds: TimeInterval?
            if let start = tab.generationStartedAt {
                let elapsed = now.timeIntervalSince(start)
                elapsedSeconds = elapsed >= 0 && elapsed <= 604_800 ? elapsed : nil
            } else {
                elapsedSeconds = nil
            }
            let completedTitle = safeTitle(message.title) ?? tab.title
            var updated = tab
            updated.state = .idle
            updated.generationID = generation
            updated.title = completedTitle
            updated.lastSeen = now
            updated.generationStartedAt = nil
            tabs[id] = updated
            onGenerationEnded?(id, generation, completedTitle, elapsedSeconds)
        default:
            return
        }
        lastMessageAt = now
    }

    private func validObservation(_ observation: Observation) -> Bool {
        observation.tabId >= 0 && observation.tabId <= Int(Int32.max) &&
        validTimestamp(observation.observedAt) &&
        (observation.generationId == nil || validGeneration(observation.generationId!)) &&
        (observation.state != .generating || observation.generationId != nil)
    }

    private func validGeneration(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 }

    private func validTimestamp(_ milliseconds: Double) -> Bool {
        guard milliseconds.isFinite, milliseconds.rounded() == milliseconds else { return false }
        let observed = Date(timeIntervalSince1970: milliseconds / 1_000)
        return abs(observed.timeIntervalSinceNow) < 300
    }

    private func validGenerationStart(_ milliseconds: Double?) -> Date? {
        guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return nil }

        let now = Date.now
        let date = Date(timeIntervalSince1970: milliseconds / 1_000)
        guard date <= now.addingTimeInterval(10), now.timeIntervalSince(date) < 7 * 24 * 3600 else {
            return nil
        }
        return date
    }

    private func expireStaleObservations() {
        let now = Date.now
        if connectionState == .connected, let lastMessageAt, now.timeIntervalSince(lastMessageAt) >= 60 {
            if let activeConnection { retiredConnection = max(retiredConnection, activeConnection) }
            activeConnection = nil
            tabs.removeAll()
            connectionState = .disconnected
            server.disconnect()
            return
        }
        for (id, tab) in tabs where tab.state != .unknown && now.timeIntervalSince(tab.lastSeen) >= 60 {
            tabs[id] = ChatGPTWebTab(tabID: id, state: .unknown, generationID: nil,
                                     title: tab.title, lastSeen: tab.lastSeen,
                                     generationStartedAt: nil)
        }
    }

    private func setupError(_ message: String) -> NSError {
        NSError(domain: "AgentPet.ChatGPTWeb", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
