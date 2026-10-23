import AppKit
import Combine
import ServiceManagement
import Sparkle
import SwiftUI
import UserNotifications

enum PetSize: String, CaseIterable, Identifiable, Hashable {
    case small, medium, large, custom

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var pixelScale: Double? {
        switch self {
        case .small:
            return 1.25

        case .medium:
            return 1.5

        case .large:
            return 2.0

        case .custom:
            return nil
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable, Hashable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AgentPetModel: ObservableObject {
    let codex = CodexClient()
    let sessions = SessionStore()
    let hooks = HookIntegration()
    let chatGPTWeb = ChatGPTWebConnector()
    let notificationManager = NotificationManager()
    let animationPlayer = AnimationPlayer()
    lazy var behaviorEngine = PetBehaviorEngine(player: animationPlayer)
    let updaterController: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feedURL = info["SUFeedURL"] as? String ?? ""
        let publicKey = info["SUPublicEDKey"] as? String ?? ""
        if !feedURL.isEmpty, !publicKey.isEmpty {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            updaterController = nil
        }

        let savedThemeID = UserDefaults.standard.string(forKey: "selectedTheme")
        let savedTheme = PetTheme.available.first { $0.id == savedThemeID } ?? PetTheme.defaultTheme
        if SpriteAtlasStore.shared.selectTheme(savedTheme) {
            selectedTheme = savedTheme
        } else if let activeTheme = SpriteAtlasStore.shared.activeTheme {
            selectedTheme = activeTheme
        } else {
            selectedTheme = PetTheme.defaultTheme
            settingsError = "No usable mascot theme is bundled with this app."
        }
    }

    @Published private(set) var selectedTheme: PetTheme
    @Published var petSize: PetSize = AgentPetModel.preference("petSize", default: .medium) {
        didSet {
            UserDefaults.standard.set(petSize.rawValue, forKey: "petSize")
            onPetSizeChange?()
        }
    }
    @Published var customPetScale = AgentPetModel.preference("customPetScale", default: 1.5) {
        didSet {
            UserDefaults.standard.set(customPetScale, forKey: "customPetScale")
            onPetSizeChange?()
        }
    }
    @Published var showUsageHUD = AgentPetModel.preference("showUsageHUD", default: true) {
        didSet {
            UserDefaults.standard.set(showUsageHUD, forKey: "showUsageHUD")
            onPetLayoutChange?()
        }
    }
    @Published var isPetPaused = AgentPetModel.preference("isPetPaused", default: false) {
        didSet { UserDefaults.standard.set(isPetPaused, forKey: "isPetPaused") }
    }
    @Published var alwaysOnTop = AgentPetModel.preference("alwaysOnTop", default: true) {
        didSet { UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop"); onPetLayoutChange?() }
    }
    @Published var keepFullyVisible = AgentPetModel.preference("keepFullyVisible", default: true) {
        didSet { UserDefaults.standard.set(keepFullyVisible, forKey: "keepFullyVisible"); onPetLayoutChange?() }
    }
    @Published var reduceMotion = AgentPetModel.preference("reduceMotion", default: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        didSet { UserDefaults.standard.set(reduceMotion, forKey: "reduceMotion") }
    }
    @Published var isPetDragging = false
    @Published var appearance: AppearanceMode = AgentPetModel.preference("appearance", default: .system) {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }
    @Published private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var settingsError: String?
    @Published private(set) var chatGPTDashboardRequest = 0
    @Published private(set) var chatGPTCompletionRevision = 0

    var onPetSizeChange: (() -> Void)?
    var onPetLayoutChange: (() -> Void)?
    var onOpenDashboard: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onHidePet: (() -> Void)?
    var onPetDragEnd: (() -> Void)?
    var onPetWillTerminate: (() -> Void)?

    var petScale: Double { petSize.pixelScale ?? customPetScale }

    var petSizeTitle: String {
        guard petSize == .custom else { return petSize.title }
        return "Custom · \(customPetScale.formatted(.number.precision(.fractionLength(1))))×"
    }

    private var connectionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var hasConnected = false
    private var isRefreshing = false

    var petState: PetState {
        sessions.petState(
            isConnected: codex.connectionState == .connected,
            isConnecting: codex.connectionState == .connecting,
            isReconnecting: codex.connectionState == .reconnecting,
            isPaused: isPetPaused
        )
    }

    var connectionTitle: String {
        switch codex.connectionState {
        case .connecting: "Connecting to Codex"
        case .connected: "Codex Connected"
        case .reconnecting: "Reconnecting to Codex"
        case .disconnected: "Codex Disconnected"
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var didCompleteOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "didCompleteOnboarding")
    }

    var latestDiagnosticError: String {
        if codex.errorMessage != nil {
            return "Codex reported an error; detailed text is omitted for privacy."
        } else if hooks.errorMessage != nil {
            return "Codex hook integration reported an error; detailed text is omitted for privacy."
        } else if settingsError != nil {
            return "A settings action reported an error; detailed text is omitted for privacy."
        } else if SpriteAtlasStore.shared.diagnosticMessage != nil {
            return "Pet asset loading reported an error."
        }
        return "none"
    }

    var diagnosticsText: String {
        let windows = codex.usage?.availableWindows.map { "\($0.label): \(Int($0.remaining.rounded(.down)))%" }.joined(separator: ", ") ?? "none"
        let updated = codex.usage?.updatedAt.formatted(date: .abbreviated, time: .shortened) ?? "not available"
        return [
            "AgentPet \(currentVersion)",
            "Codex connection: \(connectionTitle)",
            "Usage availability: \(codex.usageAvailability.rawValue)",
            "Available usage windows: \(windows)",
            "Usage updated: \(updated)",
            "Hook integration: \(hooks.state.title)",
            "Tracking: \(sessions.runningCount) running, \(sessions.needsInputCount) permission requests observed",
            "Latest error: \(latestDiagnosticError)"
        ].joined(separator: "\n")
    }

    var canAutomaticallyDownloadUpdates: Bool {
        updaterController?.updater.allowsAutomaticUpdates ?? false
    }

    var integrationActionTitle: String {
        if hooks.needsRepair { return "Repair Codex Integration" }
        if hooks.canRetryTracking { return "Retry Live Tracking" }
        return hooks.hasConfiguredHandlers ? "Disable Codex Integration" : "Enable Codex Integration"
    }

    func start() {
        codex.onUsageUpdate = { [weak self] snapshot in
            self?.notificationManager.usageChanged(snapshot)
            self?.onPetLayoutChange?()
        }
        hooks.start(
            onEvent: { [weak self] event in self?.receive(event) },
            onTrackingUnavailable: { [weak self] in self?.sessions.invalidateRuntime() }
        )
        guard connectionTask == nil else { return }
        connectionTask = Task { [weak self] in await self?.runConnectionLoop() }
        chatGPTWeb.onEnabledChange = { [weak self] in self?.onPetLayoutChange?() }
        chatGPTWeb.onShowDashboard = { [weak self] in
            guard let self else { return }
            chatGPTDashboardRequest &+= 1
            openDashboard()
        }
        chatGPTWeb.onGenerationEnded = { [weak self] tabID, generationID, chatTitle, elapsedSeconds in
            guard let self else { return }
            notificationManager.chatGPTGenerationEnded(
                tabID: tabID,
                generationID: generationID,
                chatTitle: chatTitle,
                elapsedSeconds: elapsedSeconds
            )
            chatGPTCompletionRevision &+= 1
        }
        chatGPTWeb.start()
    }

    func refreshNow() async {
        guard codex.connectionState == .connected, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let usage: Void = codex.refreshUsage()
        async let threads: Void = codex.refreshThreads(preserving: sessions.mappedLiveThreadIDs)
        _ = await (usage, threads)
        guard codex.connectionState == .connected else { return }
        sessions.updateThreads(codex.threads)
    }

    func openDashboard() { onOpenDashboard?() }
    func openSettings() { onOpenSettings?() }
    func hidePet() { onHidePet?() }

    func selectTheme(_ theme: PetTheme) {
        guard theme != selectedTheme else { return }
        guard SpriteAtlasStore.shared.selectTheme(theme) else {
            settingsError = "Unable to load the selected mascot."
            return
        }
        selectedTheme = theme
        UserDefaults.standard.set(theme.id, forKey: "selectedTheme")
        settingsError = nil
        onPetLayoutChange?()
    }

    func reconnectCodex() {
        guard reconnectTask == nil else { return }
        connectionTask?.cancel()
        connectionTask = nil
        sessions.invalidateRuntime()
        sessions.updateThreads([])
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { reconnectTask = nil }
            await codex.prepareReconnect()
            guard !Task.isCancelled else { return }
            connectionTask = Task { await runConnectionLoop() }
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "didCompleteOnboarding")
    }

    @discardableResult
    func openThread(_ id: String?) -> Bool {
        guard let id, !id.isEmpty,
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) }),
              let url = URL(string: "codex://threads/\(id)") else { return false }
        return NSWorkspace.shared.open(url)
    }

    func toggleIntegration() {
        do {
            if hooks.needsRepair {
                try hooks.enable()
            } else if hooks.canRetryTracking {
                hooks.retryTracking()
            } else if hooks.hasConfiguredHandlers {
                try hooks.disable()
                sessions.invalidateRuntime()
            } else {
                try hooks.enable()
            }
            settingsError = nil
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            settingsError = nil
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            settingsError = error.localizedDescription
        }
    }

    func checkForUpdates() { updaterController?.checkForUpdates(nil) }

    func setAutomaticUpdateChecks(_ enabled: Bool) {
        updaterController?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        updaterController?.updater.automaticallyDownloadsUpdates = enabled
    }

    func shutdown() async {
        chatGPTWeb.stop()
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        behaviorEngine.stop()
        onPetWillTerminate?()
        hooks.stop()
        await codex.shutdown()
    }

    private func receive(_ event: SessionEvent) {
        guard sessions.apply(event), let sessionID = event.sessionID else { return }
        let session = sessions.sessions[sessionID]
        let elapsedSeconds: TimeInterval?
        if (event.event == "Stop" || event.event == "Interrupt"),
           let startedAt = session?.startedAt {
            let elapsed = event.timestamp - startedAt.timeIntervalSince1970
            elapsedSeconds = elapsed >= 0 && elapsed <= 604_800 ? elapsed : nil
        } else {
            elapsedSeconds = nil
        }
        if event.event == "UserPromptSubmit" {
            Task { [weak self] in
                guard let self else { return }
                if let thread = await self.codex.findThreadMetadata(sessionID) {
                    self.sessions.mapThread(sessionID: sessionID, to: thread)
                }
            }
        }

        if ["Stop", "Interrupt", "PermissionRequest"].contains(event.event) {
            notifyAcceptedCodexEvent(event, sessionID: sessionID, elapsedSeconds: elapsedSeconds)
        } else {
            notificationManager.receive(
                event,
                chatTitle: session?.title,
                threadID: session?.threadID,
                elapsedSeconds: elapsedSeconds
            )
        }
    }

    private func notifyAcceptedCodexEvent(
        _ event: SessionEvent,
        sessionID: String,
        elapsedSeconds: TimeInterval?
    ) {
        let acceptedSession = sessions.sessions[sessionID]

        Task { @MainActor [weak self] in
            guard let self else { return }

            if self.meaningfulCodexTitle(acceptedSession?.title) == nil {
                let lookupID = acceptedSession?.threadID ?? sessionID

                Task { @MainActor [weak self] in
                    guard let self else { return }

                    if let metadata = await self.codex.findThreadMetadata(
                        lookupID,
                        refreshIfPlaceholder: true
                    ) {
                        self.sessions.mapThread(
                            sessionID: sessionID,
                            to: metadata
                        )
                    }
                }

                try? await Task.sleep(for: .milliseconds(1500))
            }

            let latest = self.sessions.sessions[sessionID]
            let selectedSession = latest?.turnID == event.turnID
                ? latest
                : acceptedSession

            self.notificationManager.receive(
                event,
                chatTitle: self.meaningfulCodexTitle(selectedSession?.title),
                threadID: selectedSession?.threadID,
                elapsedSeconds: elapsedSeconds
            )
        }
    }

    private func meaningfulCodexTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }

        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let placeholders: Set<String> = [
            "untitled thread",
            "codex session"
        ]
        guard !placeholders.contains(title.lowercased()) else { return nil }
        return title
    }

    private func runConnectionLoop() async {
        var backoff: Double = 2
        while !Task.isCancelled {
            do {
                try await codex.connect(reconnecting: hasConnected)
                hasConnected = true
                await refreshNow()
                var elapsed = 0
                while !Task.isCancelled && codex.connectionState == .connected {
                    try await Task.sleep(for: .seconds(5))
                    elapsed += 5
                    if elapsed >= 60 {
                        await refreshNow()
                        elapsed = 0
                    }
                }
                backoff = 2
            } catch {
                guard !Task.isCancelled else { break }
                hasConnected = true
                codex.markReconnecting(error)
            }
            guard !Task.isCancelled else { break }
            await codex.prepareReconnect()
            do { try await Task.sleep(for: .seconds(backoff)) } catch { break }
            backoff = min(backoff * 2, 30)
        }
    }

    private static func preference<Value: RawRepresentable>(_ key: String, default value: Value) -> Value where Value.RawValue == String {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let stored = Value(rawValue: raw) else { return value }
        return stored
    }

    private static func preference(_ key: String, default value: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return value }
        return UserDefaults.standard.bool(forKey: key)
    }

    private static func preference(_ key: String, default value: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return value }
        return UserDefaults.standard.double(forKey: key)
    }
}

@main
struct AgentPetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
                .frame(width: 440, height: 680)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct PendingNotificationTarget {
        let source: String?
        let threadID: String?
        let tabID: Int?
    }

    let model = AgentPetModel()
    private var statusItem: NSStatusItem!
    private var pet: PetPanelController!
    private var dashboard: DashboardWindowController!
    private var settings: SettingsWindowController!
    private var onboarding: OnboardingWindowController!
    private var terminationPending = false
    private var pendingNotificationTarget: PendingNotificationTarget?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        pet = PetPanelController(model: model)
        dashboard = DashboardWindowController(model: model)
        settings = SettingsWindowController(model: model)
        onboarding = OnboardingWindowController(model: model)
        model.onOpenDashboard = { [weak self] in self?.dashboard.show() }
        model.onOpenSettings = { [weak self] in self?.settings.show() }
        model.onHidePet = { [weak self] in self?.pet.hide() }
        model.onPetWillTerminate = { [weak self] in self?.pet.savePosition() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button,
           let url = Bundle.main.url(forResource: "AgentPetTemplate-18", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            button.image = image
            button.toolTip = "AgentPet"
        }
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        pet.show()
        model.start()
        if let target = pendingNotificationTarget {
            pendingNotificationTarget = nil
            handleNotificationOpen(source: target.source, threadID: target.threadID, tabID: target.tabID)
        }
        if !model.didCompleteOnboarding { onboarding.show() }
    }

    func handleNotificationOpen(source: String?, threadID: String?, tabID: Int?) {
        guard dashboard != nil else {
            pendingNotificationTarget = PendingNotificationTarget(source: source, threadID: threadID, tabID: tabID)
            return
        }

        switch source {
        case "codex":
            if !model.openThread(threadID) { dashboard.show() }
        case "chatgpt_web":
            if let tabID,
               model.chatGPTWeb.connectionState == .connected,
               model.chatGPTWeb.tabs[tabID] != nil {
                model.chatGPTWeb.openTab(tabID)
            } else {
                dashboard.show()
            }
        default:
            dashboard.show()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.connectionTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item("Show / Hide Pet", #selector(togglePet(_:))))
        menu.addItem(item("Open Dashboard", #selector(openDashboard(_:))))
        menu.addItem(item("Reconnect Codex", #selector(reconnectCodex(_:))))
        menu.addItem(item(model.integrationActionTitle, #selector(toggleIntegration(_:))))
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin(_:)))
        login.state = model.launchAtLoginEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Settings…", #selector(openSettings(_:))))
        let checkUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkUpdates.target = model.updaterController
        checkUpdates.isEnabled = model.updaterController != nil
        menu.addItem(checkUpdates)
        menu.addItem(.separator())
        menu.addItem(item("Quit AgentPet", #selector(quit(_:))))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func togglePet(_ sender: Any?) { pet.toggle() }
    @objc private func openDashboard(_ sender: Any?) { dashboard.show() }
    @objc private func reconnectCodex(_ sender: Any?) { model.reconnectCodex() }
    @objc private func toggleIntegration(_ sender: Any?) { model.toggleIntegration() }
    @objc private func toggleLaunchAtLogin(_ sender: Any?) { model.setLaunchAtLogin(!model.launchAtLoginEnabled) }
    @objc private func openSettings(_ sender: Any?) { settings.show() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }

        let info = response.notification.request.content.userInfo
        let source = info["agentpet.source"] as? String
        let threadID = info["agentpet.threadID"] as? String
        let tabID = info["agentpet.tabID"] as? Int

        await MainActor.run {
            self.handleNotificationOpen(source: source, threadID: threadID, tabID: tabID)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
