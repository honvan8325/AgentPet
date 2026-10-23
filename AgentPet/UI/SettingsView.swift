import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AgentPetModel
    @ObservedObject private var hooks: HookIntegration
    @ObservedObject private var codex: CodexClient
    @ObservedObject private var notifications: NotificationManager
    @ObservedObject private var chatGPTWeb: ChatGPTWebConnector
    @State private var webExtensionID = ""
    @State private var webInstallationError: String?
    @State private var isExtensionSetupExpanded = true

    init(model: AgentPetModel) {
        self.model = model
        _hooks = ObservedObject(wrappedValue: model.hooks)
        _codex = ObservedObject(wrappedValue: model.codex)
        _notifications = ObservedObject(wrappedValue: model.notificationManager)
        _chatGPTWeb = ObservedObject(wrappedValue: model.chatGPTWeb)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                if PetTheme.available.count == 1 {
                    LabeledContent("Mascot", value: model.selectedTheme.title)
                } else {
                    Picker(
                        "Mascot",
                        selection: Binding(
                            get: {
                                model.selectedTheme
                            },
                            set: { theme in
                                model.selectTheme(theme)
                            }
                        )
                    ) {
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
                Picker("Color appearance", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
            }

            Section("Pet Behavior") {
                Toggle("Reduce motion", isOn: $model.reduceMotion)
                Toggle("Pause AgentPet", isOn: $model.isPetPaused)
                    .help("Pauses AgentPet's animation and behavior only. Codex tasks continue running.")
            }

            Section("Codex Integration") {
                LabeledContent("App Server", value: model.connectionTitle)
                LabeledContent("Hook status", value: hooks.state.title)
                Button("Reconnect Codex") { model.reconnectCodex() }
                Button(model.integrationActionTitle) { model.toggleIntegration() }
                Text("Lifecycle events contain only event names, session IDs, turn IDs, sequence numbers, and timestamps. Permission requests are reported as observed events; Stop means a turn ended rather than succeeded.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("ChatGPT Web") {
                LabeledContent("Connection", value: chatGPTWeb.connectionState.title)
                LabeledContent("Browser", value: "Google Chrome")
                if chatGPTWeb.connectionState == .connected {
                    LabeledContent("Generating tabs", value: "\(chatGPTWeb.generatingCount)")
                }
                Toggle("Enable ChatGPT Web", isOn: Binding(
                    get: { chatGPTWeb.isEnabled },
                    set: { enabled in
                        if enabled { chatGPTWeb.enable(extensionID: webExtensionID) }
                        else { chatGPTWeb.disable() }
                    }
                ))
                Button("Open ChatGPT") { chatGPTWeb.openChatGPT() }

                DisclosureGroup(
                    "Extension setup and repair",
                    isExpanded: $isExtensionSetupExpanded
                ) {
                    Button("Install / Update Extension") {
                        do {
                            try chatGPTWeb.installOrUpdateExtension()
                            webInstallationError = nil
                        } catch { webInstallationError = error.localizedDescription }
                    }
                    TextField("Extension ID", text: $webExtensionID)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                    Button("Connect / Repair") {
                        chatGPTWeb.enable(extensionID: webExtensionID)
                    }
                    DisclosureGroup("Setup instructions") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Click Install / Update Extension.")
                            Text("2. In Chrome, enable Developer mode.")
                            Text("3. Choose Load unpacked and select the AgentPet extension folder.")
                            Text("4. Copy the Extension ID into AgentPet.")
                            Text("5. Click Connect / Repair.")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if let message = chatGPTWeb.installationMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = webInstallationError ?? chatGPTWeb.lastError {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }

            Section("Notifications") {
                Toggle("Enable notifications", isOn: $notifications.isEnabled)
                Toggle("Codex turn ended", isOn: $notifications.turnEnded).disabled(!notifications.isEnabled)
                Toggle("Codex interrupted", isOn: $notifications.interrupted).disabled(!notifications.isEnabled)
                Toggle("Permission request observed", isOn: $notifications.permissionObserved).disabled(!notifications.isEnabled)
                Toggle("Quota low or critical", isOn: $notifications.quotaAlerts).disabled(!notifications.isEnabled)
                Toggle("ChatGPT response ended", isOn: $notifications.chatGPTResponseEnded)
                    .disabled(!notifications.isEnabled)
                Text(notifications.lastChatGPTNotificationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if notifications.authorizationDenied {
                    Text("Notifications are not authorized. Enable them for AgentPet in System Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Mobile Notifications · ntfy") {
                Toggle(
                    "Enable mobile notifications",
                    isOn: $notifications.mobileEnabled
                )
                .disabled(notifications.mobileTopic == nil)

                if let topic = notifications.mobileTopic {
                    LabeledContent("Topic") {
                        Text(topic)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    Button("Copy Topic") {
                        guard let topic = notifications.mobileTopic else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(topic, forType: .string)
                    }
                } else {
                    Text("No topic configured.")
                        .foregroundStyle(.secondary)
                    Button("Generate Secure Topic") {
                        notifications.generateMobileTopic()
                    }
                }

                Button("Send Test Notification") {
                    Task { await notifications.sendMobileTest() }
                }
                .disabled(notifications.mobileTopic == nil || notifications.isTestingMobileNotification)

                Text("Events")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Toggle("Codex turn ended", isOn: $notifications.mobileCodexEnded)
                    .disabled(!notifications.mobileEnabled)
                Toggle("Codex interrupted", isOn: $notifications.mobileCodexInterrupted)
                    .disabled(!notifications.mobileEnabled)
                Toggle("Permission request observed", isOn: $notifications.mobilePermissionObserved)
                    .disabled(!notifications.mobileEnabled)
                Toggle("ChatGPT response ended", isOn: $notifications.mobileChatGPTEnded)
                    .disabled(!notifications.mobileEnabled)
                Toggle("Quota low or critical", isOn: $notifications.mobileQuotaAlerts)
                    .disabled(!notifications.mobileEnabled)

                Text("Privacy")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Toggle("Include chat titles", isOn: $notifications.mobileIncludeChatTitles)
                Text("ntfy.sh topics are public unless protected. Anyone who knows this topic may read messages. Enable chat titles only for non-sensitive work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Setup instructions") {
                    Text("1. Install ntfy on Android.\n2. Subscribe to this exact topic on ntfy.sh.\n3. Allow Android notifications for ntfy.\n4. Send a test notification.\n5. Enable mobile notifications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Status") {
                    Text(notifications.mobileLastResult ?? (notifications.mobileTopic == nil ? "No topic configured." : "Ready to send"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Desktop") {
                Toggle("Always on top", isOn: $model.alwaysOnTop)
                Toggle("Keep fully visible", isOn: $model.keepFullyVisible)
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
            }

            Section("Updates") {
                LabeledContent("Current version", value: model.currentVersion)
                Button("Check for Updates…") { model.checkForUpdates() }.disabled(model.updaterController == nil)
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { model.updaterController?.updater.automaticallyChecksForUpdates ?? false },
                    set: { enabled in
                        model.setAutomaticUpdateChecks(enabled)
                    }
                )).disabled(model.updaterController == nil)
                Toggle("Automatically download updates", isOn: Binding(
                    get: { model.updaterController?.updater.automaticallyDownloadsUpdates ?? false },
                    set: { enabled in
                        model.setAutomaticDownloads(enabled)
                    }
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
        .onAppear {
            webExtensionID = chatGPTWeb.extensionID
            isExtensionSetupExpanded = chatGPTWeb.connectionState != .connected
        }
        .onChange(of: chatGPTWeb.extensionID) { _, value in webExtensionID = value }
        .onChange(of: chatGPTWeb.connectionState) { _, state in
            isExtensionSetupExpanded = state != .connected
        }
    }
}
