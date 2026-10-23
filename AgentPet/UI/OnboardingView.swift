import SwiftUI

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
