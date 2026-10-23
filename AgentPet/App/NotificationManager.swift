import Combine
import Foundation
import Security
import UserNotifications

@MainActor
final class NotificationManager: ObservableObject {
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "notificationsEnabled")
            if isEnabled { requestAuthorization() }
        }
    }
    @Published var turnEnded = UserDefaults.standard.object(forKey: "notifyTurnEnded") == nil || UserDefaults.standard.bool(forKey: "notifyTurnEnded") {
        didSet { UserDefaults.standard.set(turnEnded, forKey: "notifyTurnEnded") }
    }
    @Published var interrupted = UserDefaults.standard.object(forKey: "notifyInterrupted") == nil || UserDefaults.standard.bool(forKey: "notifyInterrupted") {
        didSet { UserDefaults.standard.set(interrupted, forKey: "notifyInterrupted") }
    }
    @Published var permissionObserved = UserDefaults.standard.object(forKey: "notifyPermissionObserved") == nil || UserDefaults.standard.bool(forKey: "notifyPermissionObserved") {
        didSet { UserDefaults.standard.set(permissionObserved, forKey: "notifyPermissionObserved") }
    }
    @Published var quotaAlerts = UserDefaults.standard.object(forKey: "notifyQuotaAlerts") == nil || UserDefaults.standard.bool(forKey: "notifyQuotaAlerts") {
        didSet { UserDefaults.standard.set(quotaAlerts, forKey: "notifyQuotaAlerts") }
    }
    @Published var chatGPTResponseEnded = UserDefaults.standard.bool(forKey: "notifyChatGPTResponseEnded") {
        didSet { UserDefaults.standard.set(chatGPTResponseEnded, forKey: "notifyChatGPTResponseEnded") }
    }
    @Published var mobileEnabled = UserDefaults.standard.bool(forKey: "mobileNtfyEnabled") {
        didSet { UserDefaults.standard.set(mobileEnabled, forKey: "mobileNtfyEnabled") }
    }
    @Published var mobileIncludeChatTitles = UserDefaults.standard.bool(forKey: "mobileNtfyIncludeChatTitles") {
        didSet { UserDefaults.standard.set(mobileIncludeChatTitles, forKey: "mobileNtfyIncludeChatTitles") }
    }
    @Published var mobileCodexEnded = UserDefaults.standard.object(forKey: "mobileNtfyCodexEnded") == nil || UserDefaults.standard.bool(forKey: "mobileNtfyCodexEnded") {
        didSet { UserDefaults.standard.set(mobileCodexEnded, forKey: "mobileNtfyCodexEnded") }
    }
    @Published var mobileCodexInterrupted = UserDefaults.standard.object(forKey: "mobileNtfyCodexInterrupted") == nil || UserDefaults.standard.bool(forKey: "mobileNtfyCodexInterrupted") {
        didSet { UserDefaults.standard.set(mobileCodexInterrupted, forKey: "mobileNtfyCodexInterrupted") }
    }
    @Published var mobilePermissionObserved = UserDefaults.standard.object(forKey: "mobileNtfyPermissionObserved") == nil || UserDefaults.standard.bool(forKey: "mobileNtfyPermissionObserved") {
        didSet { UserDefaults.standard.set(mobilePermissionObserved, forKey: "mobileNtfyPermissionObserved") }
    }
    @Published var mobileChatGPTEnded = UserDefaults.standard.bool(forKey: "mobileNtfyChatGPTEnded") {
        didSet { UserDefaults.standard.set(mobileChatGPTEnded, forKey: "mobileNtfyChatGPTEnded") }
    }
    @Published var mobileQuotaAlerts = UserDefaults.standard.bool(forKey: "mobileNtfyQuotaAlerts") {
        didSet { UserDefaults.standard.set(mobileQuotaAlerts, forKey: "mobileNtfyQuotaAlerts") }
    }
    @Published private(set) var authorizationDenied = false
    @Published private(set) var mobileTopic: String?
    @Published private(set) var mobileLastResult: String?
    @Published private(set) var isTestingMobileNotification = false
    @Published private(set) var lastChatGPTNotificationStatus =
        "No ChatGPT completion observed in this app session."

    private let center = UNUserNotificationCenter.current()
    private var deliveredEvents = Set<String>()
    private var deliveredEventOrder: [String] = []
    private var lastQuotaAlert: [String: Date] = [:]
    private var previousRemaining: Double?
    private var previousWindowLabel: String?

    init() {
        mobileTopic = NtfyTopicStore.load()
        if mobileTopic == nil {
            if mobileEnabled {
                mobileEnabled = false
                UserDefaults.standard.set(false, forKey: "mobileNtfyEnabled")
            }
            if NtfyTopicStore.lastLoadFailed {
                mobileLastResult = "Unable to read the secure topic from Keychain."
            }
        }
    }

    func generateMobileTopic() {
        guard mobileTopic == nil else {
            mobileLastResult = "A mobile topic is already configured."
            return
        }
        guard !NtfyTopicStore.lastLoadFailed else {
            mobileEnabled = false
            mobileLastResult = "Unable to read the secure topic from Keychain."
            return
        }
        guard let topic = makeSecureNtfyTopic() else {
            mobileLastResult = "Unable to generate a secure topic."
            return
        }
        guard NtfyTopicStore.save(topic) else {
            mobileLastResult = "Unable to save the topic in Keychain."
            return
        }
        mobileTopic = topic
        mobileLastResult = "Topic created. Copy it to your ntfy app."
    }

    func receive(
        _ event: SessionEvent,
        chatTitle: String?,
        threadID: String?,
        elapsedSeconds: TimeInterval?
    ) {
        guard let sessionID = event.sessionID, let turnID = event.turnID else { return }
        let systemTitle: String
        let systemPreference: Bool
        let mobileTitle: String
        let mobilePreference: Bool
        let mobilePriority: Int
        switch event.event {
        case "Stop":
            systemTitle = "Codex turn ended"
            systemPreference = turnEnded
            mobileTitle = "AgentPet · Codex turn ended"
            mobilePreference = mobileCodexEnded
            mobilePriority = 3
        case "Interrupt":
            systemTitle = "Codex turn interrupted"
            systemPreference = interrupted
            mobileTitle = "AgentPet · Codex interrupted"
            mobilePreference = mobileCodexInterrupted
            mobilePriority = 4
        case "PermissionRequest":
            systemTitle = "Codex permission request observed"
            systemPreference = permissionObserved
            mobileTitle = "AgentPet · Permission event observed"
            mobilePreference = mobilePermissionObserved
            mobilePriority = 4
        default:
            return
        }

        let shouldSendSystem = isEnabled && systemPreference
        let shouldSendMobile = mobileEnabled && mobilePreference
        guard shouldSendSystem || shouldSendMobile else { return }
        let identifier = "\(sessionID)|\(turnID)|\(event.event)"
        guard markEventIfNew(identifier) else { return }

        if shouldSendSystem {
            post(
                identifier: identifier,
                title: systemTitle,
                body: displayChatTitle(chatTitle, fallback: "Codex session"),
                userInfo: ["agentpet.source": "codex", "agentpet.threadID": threadID ?? ""]
            )
        }

        if shouldSendMobile {
            var message = mobileIncludeChatTitles
                ? displayChatTitle(chatTitle, fallback: "Codex session")
                : "Codex activity update"
            if let duration = durationText(event.event == "PermissionRequest" ? nil : elapsedSeconds) {
                message += "\nDuration: \(duration)"
            }
            enqueueMobile(title: mobileTitle, message: message, priority: mobilePriority)
        }
    }

    func chatGPTGenerationEnded(
        tabID: Int,
        generationID: String,
        chatTitle: String?,
        elapsedSeconds: TimeInterval?
    ) {
        lastChatGPTNotificationStatus =
            "ChatGPT completion event received."
        let shouldSendSystem = isEnabled && chatGPTResponseEnded
        let shouldSendMobile = mobileEnabled && mobileChatGPTEnded
        if !shouldSendSystem && !shouldSendMobile {
            if !isEnabled {
                lastChatGPTNotificationStatus =
                    "System notifications are disabled in AgentPet."
            } else if !chatGPTResponseEnded {
                lastChatGPTNotificationStatus =
                    "ChatGPT completion notifications are disabled."
            } else {
                lastChatGPTNotificationStatus =
                    "No notification destination is enabled."
            }
            return
        }
        let identifier = "chatgpt-web|\(tabID)|\(generationID)"
        if !markEventIfNew(identifier) {
            lastChatGPTNotificationStatus =
                "Duplicate ChatGPT completion ignored."
            return
        }

        if shouldSendSystem {
            lastChatGPTNotificationStatus =
                "Submitting ChatGPT notification to macOS."
            post(
                identifier: identifier,
                title: "ChatGPT response ended",
                body: displayChatTitle(chatTitle, fallback: "ChatGPT · Tab \(tabID)"),
                userInfo: ["agentpet.source": "chatgpt_web", "agentpet.tabID": tabID],
                reportChatGPTResult: true
            )
        }

        if shouldSendMobile {
            if !shouldSendSystem {
                lastChatGPTNotificationStatus =
                    "ChatGPT notification queued for ntfy."
            }
            var message = mobileIncludeChatTitles
                ? displayChatTitle(chatTitle, fallback: "ChatGPT response ended")
                : "ChatGPT response ended"
            if let duration = durationText(elapsedSeconds) {
                message += "\nDuration: \(duration)"
            }
            enqueueMobile(
                title: "AgentPet · ChatGPT response ended",
                message: message,
                priority: 3
            )
        }
    }

    func usageChanged(_ snapshot: UsageSnapshot?) {
        defer {
            previousRemaining = snapshot?.energyWindow?.remaining
            previousWindowLabel = snapshot?.energyWindow?.label
        }
        let shouldSendSystem = isEnabled && quotaAlerts
        let shouldSendMobile = mobileEnabled && mobileQuotaAlerts
        guard shouldSendSystem || shouldSendMobile,
              let window = snapshot?.energyWindow,
              previousWindowLabel == window.label,
              let previousRemaining else { return }
        let remaining = window.remaining
        let name: String
        if previousRemaining > 18, remaining <= 18 {
            name = "critical"
        } else if previousRemaining > 40, remaining <= 40 {
            name = "low"
        } else {
            return
        }
        guard Date.now.timeIntervalSince(lastQuotaAlert[name] ?? .distantPast) >= 3_600 else { return }
        lastQuotaAlert[name] = .now
        let message = "Codex quota has dropped to \(Int(remaining.rounded(.down)))% remaining."
        if shouldSendSystem {
            post(
                identifier: "quota-\(name)-\(Int(Date.now.timeIntervalSince1970 / 3_600))",
                title: "Codex quota \(name)",
                body: message
            )
        }
        if shouldSendMobile {
            enqueueMobile(
                title: "AgentPet · Codex quota \(name)",
                message: message,
                priority: name == "critical" ? 4 : 3
            )
        }
    }

    func sendMobileTest() async {
        guard !isTestingMobileNotification else { return }
        guard let topic = mobileTopic, NtfyTopicStore.isValid(topic) else {
            mobileLastResult = "Generate a secure topic before sending a test."
            return
        }

        isTestingMobileNotification = true
        defer { isTestingMobileNotification = false }
        let payload = NtfyPublishPayload(
            topic: topic,
            title: "AgentPet · Connection Test",
            message: "AgentPet can publish to this ntfy topic.",
            priority: 3
        )

        do {
            try await NtfyPublisher.publish(payload)
            mobileLastResult = "Accepted by ntfy.sh. Check Android subscription."
        } catch let error as NtfyPublishError {
            mobileLastResult = error.displayMessage
        } catch {
            mobileLastResult = "Unable to publish notification."
        }
    }

    private func enqueueMobile(title: String, message: String, priority: Int) {
        guard mobileEnabled,
              let mobileTopic,
              NtfyTopicStore.isValid(mobileTopic)
        else {
            return
        }

        let payload = NtfyPublishPayload(
            topic: mobileTopic,
            title: title,
            message: message,
            priority: priority
        )

        Task { [weak self] in
            guard let self else { return }

            do {
                try await NtfyPublisher.publish(payload)
                mobileLastResult = "Accepted by ntfy.sh (device delivery unconfirmed)."
            } catch let error as NtfyPublishError {
                mobileLastResult = error.displayMessage
            } catch {
                mobileLastResult = "Unable to publish notification."
            }
        }
    }

    private func markEventIfNew(_ identifier: String) -> Bool {
        guard deliveredEvents.insert(identifier).inserted else { return false }
        deliveredEventOrder.append(identifier)

        if deliveredEventOrder.count > 256 {
            let oldest = deliveredEventOrder.removeFirst()
            deliveredEvents.remove(oldest)
        }

        return true
    }

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorizationDenied = !granted }
        }
    }

    private func displayChatTitle(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }

        let cleaned = raw
            .replacingOccurrences(
                of: "[\\p{Cc}\\p{Cf}]+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return fallback }

        return String(cleaned.prefix(120))
    }

    private func durationText(_ elapsed: TimeInterval?) -> String? {
        guard let elapsed, elapsed.isFinite, elapsed >= 0, elapsed <= 604_800 else { return nil }

        let seconds = Int(elapsed)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, remainder)
        }
        return "\(seconds)s"
    }

    private func post(
        identifier: String,
        title: String,
        body: String,
        userInfo: [String: Any] = [:],
        reportChatGPTResult: Bool = false
    ) {
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                authorizationDenied = true
                if reportChatGPTResult {
                    lastChatGPTNotificationStatus =
                        "macOS notification authorization is unavailable."
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = userInfo
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            do {
                try await center.add(request)
                if reportChatGPTResult {
                    lastChatGPTNotificationStatus =
                        "ChatGPT notification submitted to macOS."
                }
            } catch {
                if reportChatGPTResult {
                    lastChatGPTNotificationStatus =
                        "macOS rejected the ChatGPT notification request."
                }
            }
        }
    }
}

private struct NtfyPublishPayload: Encodable, Sendable {
    let topic: String
    let title: String
    let message: String
    let priority: Int
}

private enum NtfyPublishError: Error {
    case network
    case invalidResponse
    case httpStatus(Int)

    var displayMessage: String {
        switch self {
        case .network:
            "Cannot reach ntfy.sh. Check your connection."
        case .invalidResponse:
            "ntfy.sh returned an invalid response."
        case .httpStatus(let code):
            switch code {
            case 401, 403:
                "ntfy rejected access to this topic."
            case 404:
                "ntfy publishing endpoint unavailable."
            case 429:
                "ntfy rate limit reached. Try again later."
            case 500...599:
                "ntfy server is temporarily unavailable."
            default:
                "ntfy rejected the message (HTTP \(code))."
            }
        }
    }
}

private enum NtfyPublisher {
    static func publish(_ payload: NtfyPublishPayload) async throws {
        let url = URL(string: "https://ntfy.sh/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NtfyPublishError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw NtfyPublishError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw NtfyPublishError.httpStatus(http.statusCode)
        }
    }
}

@MainActor
private enum NtfyTopicStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.agentpet.app.mobile-ntfy",
        kSecAttrAccount as String: "topic"
    ]
    private(set) static var lastLoadFailed = false

    static func load() -> String? {
        lastLoadFailed = false
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let topic = String(data: data, encoding: .utf8),
              isValid(topic) else {
            lastLoadFailed = true
            return nil
        }
        return topic
    }

    static func save(_ topic: String) -> Bool {
        guard isValid(topic) else { return false }
        let data = Data(topic.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func isValid(_ topic: String) -> Bool {
        topic.range(of: "^agentpet-[0-9a-f]{48}$", options: .regularExpression) != nil
    }
}

private func makeSecureNtfyTopic() -> String? {
    var bytes = [UInt8](repeating: 0, count: 24)
    let status = bytes.withUnsafeMutableBytes {
        SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
    }
    guard status == errSecSuccess else { return nil }

    let randomHex = bytes.map { String(format: "%02x", $0) }.joined()
    return "agentpet-\(randomHex)"
}
