import AppKit
import SwiftUI

private func activityDuration(since start: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
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

struct DashboardView: View {
    static let contentSize = CGSize(width: 500, height: 680)

    @ObservedObject var model: AgentPetModel
    @ObservedObject private var sessions: SessionStore
    @ObservedObject private var codex: CodexClient
    @ObservedObject private var hooks: HookIntegration
    @ObservedObject private var chatGPTWeb: ChatGPTWebConnector
    @State private var diagnosticsExpanded = false

    init(model: AgentPetModel) {
        self.model = model
        _sessions = ObservedObject(wrappedValue: model.sessions)
        _codex = ObservedObject(wrappedValue: model.codex)
        _hooks = ObservedObject(wrappedValue: model.hooks)
        _chatGPTWeb = ObservedObject(wrappedValue: model.chatGPTWeb)
    }

    var body: some View {
        let tasks = sessions.dashboardTasks
        let runningTasks = tasks.filter { $0.status == .running }
        let permissionRequestsObserved = tasks.filter { $0.status == .needsInput }
        let recentTasks = tasks.filter { $0.status != .running && $0.status != .needsInput }

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
                Button { model.openSettings() } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Open Settings")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollViewReader { scroll in
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
                                if let threadID = task.threadID {
                                    Button {
                                        model.openThread(threadID)
                                    } label: {
                                        TaskRow(task: task)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    TaskRow(task: task)
                                }
                            }
                        }
                        Divider()
                        LabeledContent("Permission requests observed", value: "\(permissionRequestsObserved.count)")
                        if permissionRequestsObserved.isEmpty {
                            Text("No permission request events observed")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(permissionRequestsObserved) { task in
                                if let threadID = task.threadID {
                                    Button {
                                        model.openThread(threadID)
                                    } label: {
                                        TaskRow(task: task)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    TaskRow(task: task)
                                }
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
                                if let threadID = task.threadID {
                                    Button {
                                        model.openThread(threadID)
                                    } label: {
                                        TaskRow(task: task)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    TaskRow(task: task)
                                }
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

                    Section("ChatGPT Web") {
                        LabeledContent("Connection", value: chatGPTWeb.connectionState.title)
                        if !chatGPTWeb.isEnabled {
                            Text("Enable ChatGPT Web in Settings to monitor ChatGPT tabs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if chatGPTWeb.connectionState == .connected {
                            LabeledContent("Generating tabs", value: "\(chatGPTWeb.generatingCount)")
                            ForEach(chatGPTWeb.sortedTabs) { tab in
                                ChatGPTTabRow(tab: tab) { chatGPTWeb.openTab(tab.tabID) }
                            }
                        }
                        if let error = chatGPTWeb.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        Button("ChatGPT Web Settings…") { model.openSettings() }
                    }
                    .id("chatgpt-web")

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
                .onAppear {
                    if model.chatGPTDashboardRequest > 0 { scroll.scrollTo("chatgpt-web", anchor: .top) }
                }
                .onChange(of: model.chatGPTDashboardRequest) { _, _ in
                    scroll.scrollTo("chatgpt-web", anchor: .top)
                }
            }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
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
    @State private var isRowHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if task.status == .running, let startedAt = task.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Running · " + activityDuration(since: startedAt, now: context.date))
                                .monospacedDigit()
                        }
                    } else {
                        Text(task.status.title)
                    }
                    if task.isHistorical { Text("· History") }
                    if let source = task.source { Text("· \(source)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if task.status != .running, let updatedAt = task.updatedAt {
                Text(updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isRowHovered ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isRowHovered = $0 }
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

private struct ChatGPTTabRow: View {
    let tab: ChatGPTWebTab
    let openTab: () -> Void
    @State private var isRowHovered = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title ?? "ChatGPT · Tab \(tab.tabID)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(tab.title ?? "ChatGPT · Tab \(tab.tabID)")
                status
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open", action: openTab)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isRowHovered ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isRowHovered = $0 }
    }

    @ViewBuilder
    private var status: some View {
        switch tab.state {
        case .generating:
            if let startedAt = tab.generationStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Generating · " + activityDuration(since: startedAt, now: context.date))
                        .monospacedDigit()
                }
            } else {
                Text("Generating")
            }
        case .idle:
            Text("Idle")
        case .unknown:
            Text("Unknown")
        }
    }
}
