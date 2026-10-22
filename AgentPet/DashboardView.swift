import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AgentPetModel
    @ObservedObject private var sessions: SessionStore
    @ObservedObject private var codex: CodexClient
    @ObservedObject private var hooks: HookIntegration

    init(model: AgentPetModel) {
        self.model = model
        _sessions = ObservedObject(wrappedValue: model.sessions)
        _codex = ObservedObject(wrappedValue: model.codex)
        _hooks = ObservedObject(wrappedValue: model.hooks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AgentPet")
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                    Label(model.connectionTitle, systemImage: codex.connectionState == .connected ? "checkmark.circle.fill" : "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(codex.connectionState == .connected ? .green : .secondary)
                }
                Spacer()
                Button {
                    Task { await model.refreshNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh usage and recent threads")
            }

            UsageSummaryView(snapshot: codex.usage)

            HStack(spacing: 16) {
                Label("\(sessions.runningCount) Running", systemImage: "circle.fill")
                    .foregroundStyle(.green)
                Label("\(sessions.needsInputCount) Permission Requests Observed", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption.weight(.medium))

            if let error = codex.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Text("Codex tasks")
                    .font(.headline)
                Spacer()
                Text("\(sessions.dashboardTasks.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if sessions.dashboardTasks.isEmpty {
                ContentUnavailableView(
                    "No recent Codex tasks",
                    systemImage: "leaf",
                    description: Text("Recent threads appear here when Codex is connected.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(sessions.dashboardTasks) { task in
                            Button { model.openThread(task.threadID) } label: {
                                TaskRow(task: task)
                            }
                            .buttonStyle(.plain)
                            .disabled(task.threadID == nil)
                        }
                    }
                }
            }

            if hooks.state == .configured {
                Label("Codex integration is configured and waiting for its first lifecycle event.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            } else if hooks.state == .error {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hooks.needsRepair ? "Codex integration needs repair" : "Live tracking needs attention")
                                .font(.subheadline.weight(.semibold))
                            Text(model.settingsError ?? hooks.errorMessage ?? hooks.state.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Spacer()
                        Button(model.integrationActionTitle) {
                            model.toggleIntegration()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            } else if hooks.state == .disabled {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.path")
                            .foregroundStyle(.secondary)
                        Text("Codex lifecycle tracking is disabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("Enable Codex Integration") {
                            model.toggleIntegration()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 440, height: 620)
        .background(.regularMaterial)
        .preferredColorScheme(model.appearance.colorScheme)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AgentPetModel
    @ObservedObject private var hooks: HookIntegration
    @ObservedObject private var codex: CodexClient

    init(model: AgentPetModel) {
        self.model = model
        _hooks = ObservedObject(wrappedValue: model.hooks)
        _codex = ObservedObject(wrappedValue: model.codex)
    }

    var body: some View {
        Form {
            Section("Pet") {
                if !PetTheme.available.contains(model.selectedTheme)
                    || SpriteAssets.shared.activeTheme != model.selectedTheme {
                    LabeledContent("Mascot", value: "Unavailable")
                } else if PetTheme.available.count == 1 {
                    LabeledContent("Mascot", value: model.selectedTheme.title)
                } else {
                    Picker(
                        "Mascot",
                        selection: Binding(
                            get: { model.selectedTheme },
                            set: { model.selectTheme($0) }
                        )
                    ) {
                        ForEach(PetTheme.available) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                }
                Picker("Size", selection: $model.petSize) {
                    ForEach(PetSize.allCases) { size in Text(size.title).tag(size) }
                }
                Toggle("Show usage HUD", isOn: $model.showUsageHUD)
                Toggle("Pause AgentPet", isOn: $model.isPetPaused)
                    .help("Pauses AgentPet's animation and behavior only. Codex tasks continue running.")
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in Text(mode.rawValue.capitalized).tag(mode) }
                }
            }

            Section("Behavior") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }

            Section("Updates") {
                LabeledContent("Current version", value: model.currentVersion)
                Button("Check for Updates…") { model.checkForUpdates() }
                    .disabled(model.updaterController == nil)
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { model.updaterController?.updater.automaticallyChecksForUpdates ?? false },
                    set: { model.setAutomaticUpdateChecks($0) }
                ))
                .disabled(model.updaterController == nil)
                Toggle("Automatically download updates", isOn: Binding(
                    get: { model.updaterController?.updater.automaticallyDownloadsUpdates ?? false },
                    set: { model.setAutomaticDownloads($0) }
                ))
                .disabled(!model.canAutomaticallyDownloadUpdates)
                if model.updaterController == nil {
                    Text("Update checks are unavailable until a release feed and EdDSA public key are configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Codex integration") {
                LabeledContent("Status", value: hooks.state.title)
                if hooks.state == .configured {
                    Text("Configuration is present, but no lifecycle event has been observed in this run. Hook trust and reload status have not been verified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(model.integrationActionTitle) {
                    model.toggleIntegration()
                }
                Text("Lifecycle events contain only event names, session IDs, turn IDs, sequence numbers, and timestamps. A permission request may no longer be pending, and Stop means a turn ended rather than succeeded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.settingsError ?? hooks.errorMessage ?? codex.errorMessage {
                Section("Status") {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .preferredColorScheme(model.appearance.colorScheme)
    }
}

private struct UsageSummaryView: View {
    let snapshot: UsageSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack {
                Text("Codex usage")
                    .font(.headline)

                Spacer()

                Text(
                    snapshot.map {
                        "Updated \($0.updatedAt.formatted(date: .omitted, time: .shortened))"
                    } ?? "Unavailable"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let snapshot {

                if let fiveHour = snapshot.fiveHour {
                    UsageSummaryRow(window: fiveHour)
                }

                if let sevenDay = snapshot.sevenDay {
                    UsageSummaryRow(window: sevenDay)
                }

                if let energyWindow = snapshot.energyWindow {
                    Text(
                        "Pet energy source: \(energyWindow.label)"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if snapshot.fiveHour == nil,
                   snapshot.sevenDay != nil {

                    Text(
                        "5H unavailable — showing weekly quota only."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if snapshot.sevenDay == nil,
                   snapshot.fiveHour != nil {

                    Text(
                        "7D unavailable — showing 5H quota only."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if snapshot.availableWindows.isEmpty {
                    Text("Usage unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            } else {

                Text("Usage unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(
            .quaternary,
            in: RoundedRectangle(cornerRadius: 13)
        )
    }
}

private struct UsageSummaryRow: View {
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 9) {

            Text(window.label)
                .font(
                    .system(
                        size: 11,
                        weight: .heavy,
                        design: .rounded
                    )
                )
                .frame(
                    width: 32,
                    alignment: .leading
                )

            ProgressView(
                value: window.remaining,
                total: 100
            )
                .tint(color)

            Text(
                "\(Int(window.remaining.rounded(.down)))%"
            )
            .font(
                .system(
                    .caption,
                    design: .rounded
                )
                .monospacedDigit()
                .weight(.semibold)
            )
            .frame(
                width: 42,
                alignment: .trailing
            )
        }
        .help(
            window.resetAt.map {
                "Resets \($0.formatted(date: .abbreviated, time: .shortened))"
            } ?? "Reset time unavailable"
        )
    }

    private var color: Color {
        let remaining = window.remaining

        if remaining <= 18 { return Color(red: 0.92, green: 0.31, blue: 0.31) }
        if remaining <= 40 { return Color(red: 0.94, green: 0.66, blue: 0.22) }
        return Color(red: 0.31, green: 0.77, blue: 0.47)
    }
}

private struct TaskRow: View {
    let task: DashboardTask

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(task.status.title)
                        .fontWeight(.semibold)
                        .foregroundStyle(color)
                    if task.isLive {
                        Label("Live", systemImage: "waveform")
                    } else if task.isHistorical {
                        Label("History", systemImage: "clock")
                    }
                    if let source = task.source { Text(source) }
                    if let date = task.updatedAt { Text(date.formatted(.relative(presentation: .named))) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(task.status == .needsInput
                      ? "A permission request was observed. Whether approval is still pending is not confirmed."
                      : task.status.title)
            }
            Spacer(minLength: 0)
            if task.threadID != nil { Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var color: Color {
        switch task.status {
        case .running: .green
        case .needsInput: .orange
        case .ready: .blue
        case .interrupted: .purple
        case .unknown: .gray
        }
    }

}
