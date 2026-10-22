import AppKit
import SwiftUI

struct DashboardView: View {
    static let contentSize = CGSize(width: 500, height: 680)

    @ObservedObject var model: AgentPetModel
    @ObservedObject private var sessions: SessionStore
    @ObservedObject private var codex: CodexClient
    @ObservedObject private var hooks: HookIntegration
    @State private var diagnosticsExpanded = false

    init(model: AgentPetModel) {
        self.model = model
        _sessions = ObservedObject(wrappedValue: model.sessions)
        _codex = ObservedObject(wrappedValue: model.codex)
        _hooks = ObservedObject(wrappedValue: model.hooks)
    }

    private var runningTasks: [DashboardTask] {
        model.sessions.dashboardTasks.filter { $0.status == .running }
    }

    private var permissionRequestsObserved: [DashboardTask] {
        model.sessions.dashboardTasks.filter { $0.status == .needsInput }
    }

    private var recentTasks: [DashboardTask] {
        model.sessions.dashboardTasks.filter { $0.status != .running && $0.status != .needsInput }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AgentPet")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Label(
                        model.connectionTitle,
                        systemImage: codex.connectionState == .connected ? "checkmark.circle.fill" : "wifi.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(codex.connectionState == .connected ? .green : .secondary)
                }
                Spacer()
                Button { Task { await model.refreshNow() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh usage and recent threads")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section("Usage") {
                    UsageSummaryView(snapshot: codex.usage, availability: codex.usageAvailability)
                }

                Section {
                    LabeledContent("Running", value: "\(runningTasks.count)")
                    if runningTasks.isEmpty {
                        Label("No active tasks", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(runningTasks) { task in
                            Button { model.openThread(task.threadID) } label: { TaskRow(task: task) }
                                .buttonStyle(.plain)
                                .disabled(task.threadID == nil)
                        }
                    }
                    Divider()
                    LabeledContent("Permission requests observed", value: "\(permissionRequestsObserved.count)")
                    if permissionRequestsObserved.isEmpty {
                        Text("No permission request events observed")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(permissionRequestsObserved) { task in
                            Button { model.openThread(task.threadID) } label: { TaskRow(task: task) }
                                .buttonStyle(.plain)
                                .disabled(task.threadID == nil)
                        }
                    }
                    Text("Permission events are observations and may no longer be pending.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("Recent / historical", value: "\(recentTasks.count)")
                    if recentTasks.isEmpty {
                        Text("No recent threads")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentTasks.prefix(12)) { task in
                            Button { model.openThread(task.threadID) } label: { TaskRow(task: task) }
                                .buttonStyle(.plain)
                                .disabled(task.threadID == nil)
                        }
                    }
                } header: {
                    Text("Threads")
                }

                Section("Codex Integration") {
                    LabeledContent("Hook", value: hooks.state.title)
                    LabeledContent(
                        "Tracking",
                        value: "\(sessions.runningCount) running · \(sessions.needsInputCount) permission requests observed"
                    )
                    HStack {
                        Button("Reconnect Codex") { model.reconnectCodex() }
                        Spacer()
                        Button(model.integrationActionTitle) { model.toggleIntegration() }
                    }
                    if let error = model.settingsError ?? hooks.errorMessage ?? codex.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                Section("Settings") {
                    LabeledContent("Mascot", value: "\(model.selectedTheme.title) · \(model.petSizeTitle)")
                    LabeledContent("Notifications", value: model.notificationManager.isEnabled ? "On" : "Off")
                    if model.notificationManager.authorizationDenied {
                        Label("Allow alerts in System Settings to receive notifications.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Open Settings…") { model.openSettings() }
                }

                Section {
                    DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Usage", value: codex.usageAvailability.rawValue.capitalized)
                            LabeledContent("Hook", value: hooks.state.title)
                            LabeledContent("Tracking", value: hooks.canRetryTracking ? "Retry available" : "Current")
                            LabeledContent("Version", value: model.currentVersion)
                            LabeledContent("Latest error", value: model.latestDiagnosticError)
                            if let message = SpriteAtlasStore.shared.diagnosticMessage {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Copy Diagnostics") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.diagnosticsText, forType: .string)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Diagnostics")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(model.appearance.colorScheme)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AgentPetModel
    @ObservedObject private var hooks: HookIntegration
    @ObservedObject private var codex: CodexClient
    @ObservedObject private var notifications: NotificationManager

    init(model: AgentPetModel) {
        self.model = model
        _hooks = ObservedObject(wrappedValue: model.hooks)
        _codex = ObservedObject(wrappedValue: model.codex)
        _notifications = ObservedObject(wrappedValue: model.notificationManager)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                if PetTheme.available.count == 1 {
                    LabeledContent("Mascot", value: model.selectedTheme.title)
                } else {
                    Picker("Mascot", selection: Binding(get: { model.selectedTheme }, set: model.selectTheme)) {
                        ForEach(PetTheme.available) { Text($0.title).tag($0) }
                    }
                }
                Picker("Pet size", selection: $model.petSize) {
                    ForEach(PetSize.allCases) { Text($0.title).tag($0) }
                }
                if model.petSize == .custom {
                    LabeledContent("Custom scale") {
                        HStack(spacing: 10) {
                            Slider(value: $model.customPetScale, in: 1.0...3.0, step: 0.1)
                                .accessibilityLabel("Custom pet scale")
                            Text("\(model.customPetScale.formatted(.number.precision(.fractionLength(1))))×")
                                .monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                }
                Toggle("Show usage HUD", isOn: $model.showUsageHUD)
                Toggle("Always on top", isOn: $model.alwaysOnTop)
                Toggle("Keep fully visible", isOn: $model.keepFullyVisible)
                Toggle("Reduce motion", isOn: $model.reduceMotion)
                Toggle("Pause AgentPet", isOn: $model.isPetPaused)
                    .help("Pauses AgentPet's animation and behavior only. Codex tasks continue running.")
                Picker("Color appearance", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
            }

            Section("Notifications") {
                Toggle("Enable notifications", isOn: $notifications.isEnabled)
                Toggle("Codex turn ended", isOn: $notifications.turnEnded).disabled(!notifications.isEnabled)
                Toggle("Codex interrupted", isOn: $notifications.interrupted).disabled(!notifications.isEnabled)
                Toggle("Permission request observed", isOn: $notifications.permissionObserved).disabled(!notifications.isEnabled)
                Toggle("Quota low or critical", isOn: $notifications.quotaAlerts).disabled(!notifications.isEnabled)
                if notifications.authorizationDenied {
                    Text("Notifications are not authorized. Enable them for AgentPet in System Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Desktop") {
                Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLoginEnabled }, set: model.setLaunchAtLogin))
            }

            Section("Codex Integration") {
                LabeledContent("App Server", value: model.connectionTitle)
                LabeledContent("Hook status", value: hooks.state.title)
                Button("Reconnect Codex") { model.reconnectCodex() }
                Button(model.integrationActionTitle) { model.toggleIntegration() }
                Text("Lifecycle events contain only event names, session IDs, turn IDs, sequence numbers, and timestamps. Permission requests are reported as observed events; Stop means a turn ended rather than succeeded.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Updates") {
                LabeledContent("Current version", value: model.currentVersion)
                Button("Check for Updates…") { model.checkForUpdates() }.disabled(model.updaterController == nil)
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { model.updaterController?.updater.automaticallyChecksForUpdates ?? false },
                    set: model.setAutomaticUpdateChecks
                )).disabled(model.updaterController == nil)
                Toggle("Automatically download updates", isOn: Binding(
                    get: { model.updaterController?.updater.automaticallyDownloadsUpdates ?? false },
                    set: model.setAutomaticDownloads
                )).disabled(!model.canAutomaticallyDownloadUpdates)
                if model.updaterController == nil {
                    Text("Update checks are unavailable until a release feed and EdDSA public key are configured.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let error = model.settingsError ?? hooks.errorMessage ?? codex.errorMessage {
                Section("Status") { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .preferredColorScheme(model.appearance.colorScheme)
    }
}

private struct UsageSummaryView: View {
    let snapshot: UsageSnapshot?
    let availability: UsageAvailability

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot, !snapshot.availableWindows.isEmpty {
                ForEach(snapshot.availableWindows) { UsageSummaryRow(window: $0) }
                HStack {
                    Text(snapshot.energyWindow.map { "Pet energy · \($0.label)" } ?? "Pet energy unavailable")
                    Spacer()
                    Text(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label(
                    availability == .loading ? "Loading quota…" : "Usage unavailable",
                    systemImage: availability == .loading ? "arrow.triangle.2.circlepath" : "chart.bar.xaxis"
                )
                .foregroundStyle(.secondary)
                Text("Pet energy unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct UsageSummaryRow: View {
    let window: UsageWindow

    private var remaining: Double { min(100, max(0, window.remaining)) }

    var body: some View {
        HStack(spacing: 9) {
            Text(window.label).font(.system(size: 11, weight: .heavy, design: .rounded)).frame(width: 32, alignment: .leading)
            ProgressView(value: remaining, total: 100).tint(color)
            Text("\(Int(remaining.rounded(.down)))%")
                .font(.system(.caption, design: .rounded).monospacedDigit().weight(.semibold))
                .frame(width: 42, alignment: .trailing)
        }
        .help(window.resetAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Reset time unavailable")
    }

    private var color: Color {
        if remaining <= 18 { return Color(red: 0.92, green: 0.31, blue: 0.31) }
        if remaining <= 40 { return Color(red: 0.94, green: 0.66, blue: 0.22) }
        return Color(red: 0.31, green: 0.77, blue: 0.47)
    }
}

private struct TaskRow: View {
    let task: DashboardTask

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(task.status.title)
                    if task.isHistorical { Text("· History") }
                    if let source = task.source { Text("· \(source)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let updatedAt = task.updatedAt {
                Text(updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .help(task.title)
    }

    private var color: Color {
        switch task.status {
        case .running: .green
        case .needsInput: .orange
        case .ready: .blue
        case .interrupted: .red
        case .unknown: .gray
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AgentPetModel
    @ObservedObject private var hooks: HookIntegration
    @ObservedObject private var codex: CodexClient
    @ObservedObject private var notifications: NotificationManager
    let onComplete: () -> Void
    @State private var page = 0

    init(model: AgentPetModel, onComplete: @escaping () -> Void) {
        self.model = model
        self.onComplete = onComplete
        _hooks = ObservedObject(wrappedValue: model.hooks)
        _codex = ObservedObject(wrappedValue: model.codex)
        _notifications = ObservedObject(wrappedValue: model.notificationManager)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Step \(page + 1) of 3").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("AgentPet").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            switch page {
            case 0:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Welcome to AgentPet").font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("A small desktop companion for Codex. The pet stays available while you work and shows only task states AgentPet can confirm.")
                    Label("Your Chick can be moved by dragging it.", systemImage: "hand.draw")
                    Label("Quota and live task tracking are optional.", systemImage: "chart.bar")
                }
            case 1:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Configure Codex Integration").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Enable or repair the Codex lifecycle hook, then review and trust its handlers in Codex. Reload Codex if requested; AgentPet will not restart it. The pet remains available if Codex is unavailable.")
                    Button(model.integrationActionTitle) { model.toggleIntegration() }.buttonStyle(.borderedProminent)
                    LabeledContent("Hook status", value: hooks.state.title)
                    LabeledContent("Codex", value: model.connectionTitle)
                }
            default:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose your pet settings").font(.system(size: 24, weight: .bold, design: .rounded))
                    LabeledContent("Mascot", value: model.selectedTheme.title)
                    Toggle("Show usage HUD", isOn: $model.showUsageHUD)
                    Toggle("Enable notifications", isOn: $notifications.isEnabled)
                    Text("You can change these options later in Settings.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack {
                if page > 0 { Button("Back") { page -= 1 } }
                Spacer()
                if page < 2 {
                    Button("Continue") { page += 1 }.buttonStyle(.borderedProminent)
                } else {
                    Button("Finish") { model.completeOnboarding(); onComplete() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(model.appearance.colorScheme)
    }
}
