import AppKit
import Combine
import ServiceManagement
import Sparkle
import SwiftUI

enum PetSize: String, CaseIterable, Identifiable, Hashable {
    case small, medium, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var pixelScale: Int {
        switch self {
        case .small: 1
        case .medium: 2
        case .large: 3
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
        if SpriteAssets.shared.selectTheme(savedTheme) {
            selectedTheme = savedTheme
        } else if let activeTheme = SpriteAssets.shared.activeTheme {
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
    @Published var showUsageHUD = AgentPetModel.preference("showUsageHUD", default: true) {
        didSet {
            UserDefaults.standard.set(showUsageHUD, forKey: "showUsageHUD")
            onPetLayoutChange?()
        }
    }
    @Published var isPetPaused = AgentPetModel.preference("isPetPaused", default: false) {
        didSet { UserDefaults.standard.set(isPetPaused, forKey: "isPetPaused") }
    }
    @Published var appearance: AppearanceMode = AgentPetModel.preference("appearance", default: .system) {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }
    @Published private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var settingsError: String?

    var onPetSizeChange: (() -> Void)?
    var onPetLayoutChange: (() -> Void)?
    var onOpenDashboard: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onHidePet: (() -> Void)?
    var onPetDragEnd: (() -> Void)?
    var onPetWillTerminate: (() -> Void)?

    private var connectionTask: Task<Void, Never>?
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

    var canAutomaticallyDownloadUpdates: Bool {
        updaterController?.updater.allowsAutomaticUpdates ?? false
    }

    var integrationActionTitle: String {
        if hooks.needsRepair { return "Repair Codex Integration" }
        if hooks.canRetryTracking { return "Retry Live Tracking" }
        return hooks.hasConfiguredHandlers ? "Disable Codex Integration" : "Enable Codex Integration"
    }

    func start() {
        hooks.start(
            onEvent: { [weak self] event in self?.receive(event) },
            onTrackingUnavailable: { [weak self] in self?.sessions.invalidateRuntime() }
        )
        guard connectionTask == nil else { return }
        connectionTask = Task { [weak self] in await self?.runConnectionLoop() }
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
        guard SpriteAssets.shared.selectTheme(theme) else {
            settingsError = "Unable to load the selected mascot."
            return
        }
        selectedTheme = theme
        UserDefaults.standard.set(theme.id, forKey: "selectedTheme")
        settingsError = nil
    }

    func openThread(_ id: String?) {
        guard let id, !id.isEmpty,
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) }),
              let url = URL(string: "codex://threads/\(id)") else { return }
        NSWorkspace.shared.open(url)
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
        connectionTask?.cancel()
        connectionTask = nil
        onPetWillTerminate?()
        hooks.stop()
        await codex.shutdown()
    }

    private func receive(_ event: SessionEvent) {
        guard sessions.apply(event), let sessionID = event.sessionID else { return }

        if event.event == "UserPromptSubmit" {
            Task { [weak self] in
                guard let self else { return }
                if let thread = await self.codex.findThreadMetadata(sessionID) {
                    self.sessions.mapThread(sessionID: sessionID, to: thread)
                }
            }
        }
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
}

@main
struct AgentPetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
                .frame(width: 420, height: 500)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AgentPetModel()
    private var statusItem: NSStatusItem!
    private var pet: PetPanelController!
    private var dashboard: DashboardWindowController!
    private var settings: SettingsWindowController!
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        pet = PetPanelController(model: model)
        dashboard = DashboardWindowController(model: model)
        settings = SettingsWindowController(model: model)
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
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.connectionTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item("Show / Hide Pet", #selector(togglePet(_:))))
        menu.addItem(item("Open Dashboard", #selector(openDashboard(_:))))
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
