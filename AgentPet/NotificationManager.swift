import Combine
import Foundation
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
    @Published private(set) var authorizationDenied = false

    private let center = UNUserNotificationCenter.current()
    private var deliveredEvents = Set<String>()
    private var deliveredEventOrder: [String] = []
    private var lastQuotaAlert: [String: Date] = [:]
    private var previousRemaining: Double?
    private var previousWindowLabel: String?

    func receive(_ event: SessionEvent) {
        guard isEnabled, let sessionID = event.sessionID, let turnID = event.turnID else { return }
        let title: String
        let body: String
        let preference: Bool
        switch event.event {
        case "Stop":
            title = "Codex turn ended"
            body = "A Codex turn has ended."
            preference = turnEnded
        case "Interrupt":
            title = "Codex turn interrupted"
            body = "A Codex turn was interrupted."
            preference = interrupted
        case "PermissionRequest":
            title = "Permission request observed"
            body = "Codex reported a permission request event. Check Codex to see whether it is still pending."
            preference = permissionObserved
        default:
            return
        }
        guard preference else { return }
        let identifier = "\(sessionID)|\(turnID)|\(event.event)"
        guard deliveredEvents.insert(identifier).inserted else { return }
        deliveredEventOrder.append(identifier)
        if deliveredEventOrder.count > 256 {
            deliveredEvents.remove(deliveredEventOrder.removeFirst())
        }
        post(identifier: identifier, title: title, body: body)
    }

    func usageChanged(_ snapshot: UsageSnapshot?) {
        defer {
            previousRemaining = snapshot?.energyWindow?.remaining
            previousWindowLabel = snapshot?.energyWindow?.label
        }
        guard isEnabled, quotaAlerts, let window = snapshot?.energyWindow,
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
        post(
            identifier: "quota-\(name)-\(Int(Date.now.timeIntervalSince1970 / 3_600))",
            title: "Codex quota \(name)",
            body: "Codex quota has dropped to \(Int(remaining.rounded(.down)))% remaining."
        )
    }

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorizationDenied = !granted }
        }
    }

    private func post(identifier: String, title: String, body: String) {
        let center = self.center
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                Task { @MainActor [weak self] in self?.authorizationDenied = true }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request)
        }
    }
}
