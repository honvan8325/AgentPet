# AgentPet 🐣

**A native macOS desktop companion for Codex and ChatGPT Web.**

AgentPet puts an animated pixel-art Chick on your desktop. It reacts to observable AI activity, shows available Codex usage, and can notify you when a turn ends or an event needs attention—on your Mac or, optionally, on Android through ntfy.

AgentPet reports **observed states**, not assumptions: a Codex `Stop` means the turn ended, not that it succeeded; a permission event may no longer be pending; and a ChatGPT response is considered finished only when the browser connector confirms an end event.

## Features

| Feature | What it does |
| --- | --- |
| Pixel-art Chick | Animated desktop pet with idle, work, connection, energy, and interaction behaviors |
| Codex tracking | Observes `UserPromptSubmit`, `Stop`, `Interrupt`, and `PermissionRequest` through the Codex hook integration |
| Usage HUD | Shows available Codex usage windows (such as 5-hour and 7-day) and remaining percentages |
| ChatGPT Web | Observes generating ChatGPT tabs in Google Chrome through a Manifest V3 extension and native bridge |
| Task bubbles | Shows separate counts for running Codex sessions and generating ChatGPT tabs; click to navigate |
| Dashboard | Live/recent activity, observed permission events, task duration when known, usage, connection health, and diagnostics |
| macOS notifications | Optional event notifications with available chat titles and click-through to verified Codex threads or existing Chrome tabs |
| Android notifications | Optional ntfy push notifications with independent event preferences and a chat-title privacy toggle |
| Desktop preferences | Pet size, HUD, appearance, Pause, Reduce Motion, always-on-top, keep-visible, and Launch at Login |
| Updates | Sparkle update checks and a signed appcast for published releases |

> **Limitations:** Conversation titles are best-effort metadata, not guaranteed. AgentPet does not guess names from entire chats. Task bubbles intentionally **do not open hover popovers**.

## Requirements

- **macOS 14 or later.**
- **Codex integration:** ChatGPT Desktop with the bundled Codex CLI/App Server expected by this project, plus working Codex lifecycle hooks.
- **ChatGPT Web integration (optional):** Google Chrome and a signed-in session at [chatgpt.com](https://chatgpt.com/).
- **Build from source:** Xcode 16 or later with Swift 6 support; internet access to resolve the Sparkle Swift package.
- **Android push (optional):** The [ntfy](https://ntfy.sh/) Android app; no separate AgentPet Android app is required.

Codex, Chrome, and mobile notifications are separate capabilities. The Chick can stay visible even when a connector is unavailable.

## Install

1. Download the latest DMG from [GitHub Releases](https://github.com/honvan8325/AgentPet/releases/latest).
2. Open the DMG and drag `AgentPet.app` to **Applications**.
3. Launch AgentPet and follow the three-step onboarding flow.
4. Configure Codex and, optionally, ChatGPT Web and notifications in **Settings**.

**macOS security note:** Current release builds are ad hoc signed and **not Apple-notarized**. macOS may warn on first launch. Only install a build from a source you trust; review the warning and macOS security settings rather than disabling Gatekeeper globally.

### Set up Codex

1. Open **AgentPet → Settings → Codex Integration** (or complete onboarding).
2. Choose **Enable Codex Integration**. If an integration is already present, the button may instead say **Repair Codex Integration**, **Retry Live Tracking**, or **Disable Codex Integration** depending on its state.
3. Review and trust the configured handlers in Codex, and reload Codex if requested. AgentPet will not restart it for you.
4. Start a **new Codex turn**. The Dashboard should show the detected activity when the hook is working.

AgentPet installs a native hook collector and updates `~/.codex/hooks.json` while preserving unrelated handlers. A hook-based live session is distinct from a historical thread returned by the App Server. Sessions active before tracking began may not have a verified running state or start time.

The **App Server** connection supplies usage and thread metadata. **Hook integration** supplies lifecycle observations. Both contribute to the displayed session state; losing one may limit what AgentPet can confirm.

### Set up ChatGPT Web in Chrome

1. Open **Settings → ChatGPT Web** and click **Install / Update Extension**.
2. In Chrome, visit `chrome://extensions` and enable **Developer mode**.
3. Click **Load unpacked** and select:

   ```text
   ~/Library/Application Support/AgentPet/ChatGPTExtension
   ```

4. Copy the **extension ID** shown by Chrome into AgentPet's **Extension ID** field.
5. Click **Connect / Repair**, then enable **ChatGPT Web** if it is not already enabled.
6. Open or refresh [chatgpt.com](https://chatgpt.com/). Confirm that Settings shows **Connected** when the extension connects.

The extension is designed for Google Chrome, not an arbitrary Chromium browser. It uses Chrome's `nativeMessaging`, `tabs`, and `alarms` permissions and runs only on `https://chatgpt.com/*`.

**After updating the extension:** Run **Install / Update Extension** again, reload the unpacked extension in `chrome://extensions`, then refresh open ChatGPT pages. If the native bridge code changed, **rebuild and relaunch AgentPet as well**; reloading JavaScript cannot update a compiled helper executable.

## Using AgentPet

### Chick and task bubbles

- **Drag the Chick** to reposition it on your desktop.
- **Click, double-click, or interact with the Chick** to see supported reactions; available reactions depend on its current state.
- **Codex bubble:** Displays the number of confirmed running Codex sessions. Clicking it opens the Dashboard.
- **ChatGPT bubble:** Displays the number of generating Chrome tabs. Clicking it attempts to activate a relevant existing ChatGPT tab.
- **Two visible bubbles:** Use the existing diagonal layout. Hovering either bubble does **not** open a task-list popover.
- **Usage HUD:** Shows available quota windows. Hover over a bar to see the corresponding percentage.

The Chick adapts its visual behavior to connection/activity states and supported energy profiles. Pausing the pet pauses its animation/behavior; **it does not pause Codex tasks or stop browser monitoring**.

### Dashboard

The Dashboard provides:

- **Usage:** Available Codex windows, remaining quota, and reset information when provided.
- **Threads:** Confirmed running sessions, observed permission requests, and recent/historical tasks.
- **Activity duration:** `Running · 2m 35s` or `Generating · 1m 12s` only if a valid start timestamp was observed.
- **Codex Integration:** App Server and hook/tracking status, with recovery actions.
- **ChatGPT Web:** Observed tabs, their best-effort titles and activity states, and an **Open** action.
- **Diagnostics:** Limited connection/tracking information that avoids exposing conversation content.

A thread row can open a Codex thread only when AgentPet has a verified thread identifier. An observed `PermissionRequest` is **not** proof that an approval dialog is still waiting. Unknown or stale activity is not shown as confirmed running work.

### Notifications on macOS

Open **Settings → Notifications** and enable the events you want:

- Codex turn ended
- Codex interrupted
- Permission request observed
- Quota low or critical
- ChatGPT response ended (**off by default**)

Turn on **Enable notifications** and grant permission in macOS System Settings when requested. Actual banner/alert presentation and its duration are controlled by macOS.

Notifications show the available chat/thread title if AgentPet can resolve one, otherwise a neutral label such as `Codex session` or `ChatGPT · Tab 42`. Clicking a notification attempts to open its verified Codex thread or still-available Chrome tab; if that is not possible, AgentPet opens the Dashboard.

**Important:** `Stop` does not prove success. A browser tab close, navigation, disconnect, or manual stop is not automatically treated as a completed ChatGPT response.

### Android push notifications with ntfy (optional)

AgentPet can publish selected event notifications to [ntfy](https://ntfy.sh/) without a separate Android application or a backend you operate.

1. Install ntfy on your Android device and allow its notifications.
2. In AgentPet, open **Settings → Mobile Notifications · ntfy**.
3. Click **Generate Secure Topic** once, then **Copy Topic**.
4. In the Android app, subscribe to the **exact topic** on the `ntfy.sh` server.
5. Click **Send Test Notification** in AgentPet and confirm that Android received it.
6. Enable **mobile notifications**, then choose which events should be forwarded.
7. Enable **Include chat titles** only if you accept the privacy implications.

Mobile settings are independent of macOS notification settings. ChatGPT completion and quota pushes are off by default; individual Codex event options are available when you enable mobile notifications. Events can include elapsed duration if AgentPet observed a trustworthy start time.

**Privacy warning:** Public `ntfy.sh` topics are not authenticated or end-to-end encrypted simply because their names are random. Anyone who knows the topic may subscribe, and messages can pass through service/push infrastructure. AgentPet generates a cryptographically random topic and stores it in the **macOS Keychain**, but that does **not** make message contents private. Chat-title forwarding is **off by default**; leave it off for sensitive work, or use a separate access-controlled solution.

**Delivery status:** “Accepted by ntfy.sh” means the server accepted the HTTP publish request; it is **not** confirmation of display on Android. AgentPet does not guarantee delivery when the Mac is offline or the app quits mid-request.

## Settings reference

| Group | Main controls |
| --- | --- |
| Appearance | Chick theme, Small/Medium/Large/Custom size, usage HUD, light/dark/system appearance |
| Pet Behavior | Reduce Motion, Pause AgentPet |
| Codex Integration | Connection state, hook state, reconnect, enable/repair/retry/disable integration |
| ChatGPT Web | Connection and generating-tab status, open ChatGPT, extension setup and repair |
| Notifications | macOS notification enable switch, per-event switches, ChatGPT notification diagnostic status |
| Mobile Notifications · ntfy | Secure topic, copy, test, event switches, optional titles, privacy notice, publish status |
| Desktop | Always on top, keep fully visible, Launch at Login |
| Updates | Version, manual update check, automatic checks/downloads when available |

Pet size presets are Small **1.25×**, Medium **1.5×**, and Large **2.0×**. Custom size ranges from **1.0× to 3.0×** in steps of **0.1×**. Chick is currently the only bundled theme.

## How it works

```text
Codex CLI / App Server ────────────────────────┐
                                               ├─> AgentPetModel / SessionStore
Codex lifecycle hooks → AgentPetHook → journal ┘                │
                                                               ├─> Dashboard & duration
ChatGPT Web page → content.js → background.js                  ├─> PetBehaviorEngine
    → Chrome Native Messaging → AgentPetWebBridge               │     → AnimationPlayer
    → ChatGPTWebNativeServer → ChatGPTWebConnector ─────────────┤     → SpriteAtlasStore
                                                               ├─> macOS notifications
                                                               └─> ntfy (optional)
```

### Codex lifecycle

The native hook collector observes event names, session/turn IDs, sequence numbers, and timestamps. AgentPet uses accepted events to update live session state; the App Server provides separate usage/thread metadata. Session-to-thread matching avoids guessing when a mapping is ambiguous. A bounded metadata lookup may fail to resolve a title before a notification is sent, in which case the fallback is intentional.

### ChatGPT Web lifecycle

The Chrome extension detects observed page activity and forwards accepted messages through a local Native Messaging bridge. Page/route identity, sequence numbers, generation identity, freshness, and duplicate-completion checks help prevent events from old pages or tabs from being misclassified.

Chrome `Tab.title` and the currently selected conversation navigation label may be used as **best-effort** title sources. The ChatGPT site can change its DOM or leave a title generic, so AgentPet cannot guarantee the official conversation name for every generation. The extension does not need to read entire messages to derive a title.

### Rendering and assets

Chick uses **Asset System V3** with **88 animation clips** (64 behavior clips and 24 transitions), **5 energy profiles**, **6 moods**, **2,640 animation variants**, **19,680 individually timed frames**, and **308 atlas pages**. Sprite frames are displayed with nearest-neighbor sampling to preserve pixel edges. Atlas pages are loaded on demand with a bounded in-memory cache rather than preloading the entire theme.

Runtime assets live in `AgentPet/Resources/Themes/chick/` and include `manifest.json`, `behavior.json`, atlas PNGs, HUD/bubble sprites, and effect frames. Editable source art and asset-generation utilities are not part of this repository.

## Build from source

Open `AgentPet.xcodeproj` in Xcode and select the **AgentPet** scheme. The project has three targets:

- `AgentPet` — macOS application.
- `AgentPetHook` — Codex lifecycle hook collector.
- `AgentPetWebBridge` — Chrome Native Messaging helper.

Resolve the Sparkle dependency and build:

```bash
xcodebuild -resolvePackageDependencies \
  -project AgentPet.xcodeproj \
  -scheme AgentPet

xcodebuild \
  -project AgentPet.xcodeproj \
  -scheme AgentPet \
  -configuration Debug \
  CODE_SIGN_IDENTITY=- \
  build
```

These commands require Xcode/macOS and do not produce an Apple-notarized release. For ChatGPT integration, run the **newly built app and bundled helper** and update/reload the Chrome extension as described above.

## Repository layout

```text
AgentPet/
  App/
    AgentPetApp.swift              # App lifecycle, application model, menus/windows
    NotificationManager.swift      # macOS and optional ntfy notifications
  Connectors/
    Codex/
      CodexClient.swift            # Codex App Server connection, usage, thread metadata
      HookIntegration.swift        # Lifecycle hook installation and event journal
      SessionStore.swift           # Accepted live sessions and Dashboard tasks
    ChatGPTWeb/
      ChatGPTWebConnector.swift    # Native messages, tab states and completion events
      ChatGPTWebNativeServer.swift # Local socket server
  Pet/
    AnimationPlayer.swift          # Clip/frame and effect playback
    AssetManifest.swift            # V3 manifest decoding
    PetBehaviorEngine.swift        # Event- and interaction-driven behavior
    PetTheme.swift                 # Theme discovery
    PetView.swift                  # Chick, bubbles and quota HUD
    PetWindow.swift                # Desktop panel and window behavior
    SpriteAtlasStore.swift         # On-demand atlas cache
  UI/
    DashboardView.swift
    SettingsView.swift
    OnboardingView.swift
  Resources/
    BrowserExtension/ChatGPTWeb/
      manifest.json
      background.js
      content.js
    Themes/chick/                  # V3 manifests, atlases, HUD, effects
  Assets.xcassets/
  Info.plist
AgentPetHook/main.swift
AgentPetWebBridge/main.swift
AgentPet.xcodeproj/
.github/workflows/release.yml
README.md
```

## Troubleshooting

### Codex shows `Codex session` instead of a thread name

The lifecycle hook can identify a turn before the App Server provides a meaningful thread name or preview. A notification may be sent while metadata lookup is still pending, or no unambiguous thread mapping may exist. Check **Codex App Server** and **Hook status** in Settings, then start a new turn. A fallback label does not mean that the turn-completion event failed. AgentPet does not automatically create a thread name from your prompt.

### No ChatGPT completion notification appears

1. Check that **ChatGPT Web** is enabled and displays **Connected**.
2. In **Settings → Notifications**, enable **Enable notifications** and **ChatGPT response ended** (off by default).
3. Confirm AgentPet is allowed to show notifications in **macOS System Settings → Notifications**.
4. Reinstall/update the bundled extension, reload it at `chrome://extensions`, and refresh ChatGPT tabs.
5. If AgentPet or `AgentPetWebBridge` changed, rebuild and relaunch the actual application, not only the extension.
6. Generate a new response and let it finish naturally. The connector intentionally does not infer completion from tab closing, navigating away, disconnecting, or manually stopping.
7. Read the ChatGPT notification status displayed in Settings to distinguish an unobserved completion from a disabled notification or a rejected macOS request.

If Chrome shows `Uncaught ReferenceError` in `content.js`, ensure the installed extension files match the latest build; editing the repository alone does not replace the unpacked files already loaded by Chrome.

### ChatGPT shows `ChatGPT · Tab N` instead of a conversation title

The browser title may be generic, and the selected conversation title may not be available in the page navigation DOM. AgentPet uses neutral fallback metadata rather than pretending to know a title. Updating the extension can help if Chrome is still running older scripts, but does not guarantee that ChatGPT's current site exposes a usable name.

### The Chrome connector is disconnected

Check the extension ID, the **Connect / Repair** action, Chrome's unpacked extension status, and whether you refreshed ChatGPT pages after reloading the extension. Rebuild/relaunch the app when the compiled native helper changes. The bridge and content script must be from compatible versions of AgentPet.

### No Android ntfy notification arrives

Confirm your phone is subscribed to the exact generated topic on `ntfy.sh`, Android notifications are enabled, and **Send Test Notification** reports the request was accepted. Check the phone's network and notification restrictions. Publishing success does not establish Android delivery. Keep chat titles off unless you accept the topic's public-access model.

### Quota or activity is unavailable

Unavailable quota is not interpreted as 0%. Codex App Server usage can be missing or delayed; unknown session continuity is not displayed as confirmed activity. Use **Reconnect Codex** or **Retry Live Tracking** when relevant. Avoid assuming that historical threads reflect currently running turns.

## Releases and updates

Pushing a semantic-version tag such as `v1.2.3` triggers `.github/workflows/release.yml`.

The workflow validates release metadata and the Chick V3 assets, builds the **arm64** app and both helpers, verifies the bundled extension and frameworks, packages a **DMG** and **Sparkle ZIP**, writes **SHA-256 checksums**, signs the appcast update with **Sparkle EdDSA**, publishes the GitHub Release, and deploys the appcast through GitHub Pages.

Release configuration uses:

- GitHub Actions secret: `SPARKLE_PRIVATE_KEY`
- GitHub Actions variable: `SPARKLE_PUBLIC_ED_KEY`

The private and public Sparkle keys must match. **Sparkle update signing is not the same as Apple code signing or notarization.** Current releases use ad hoc signing and are not notarized.

## Privacy and data handling

- Codex hooks record lifecycle metadata in `~/Library/Application Support/AgentPet/events.jsonl`, not full chat transcripts.
- AgentPet reads Codex usage and thread metadata through the App Server and uses only verified/observed state for live tracking.
- The Chrome extension observes ChatGPT page status and limited title metadata; it does not intentionally collect full prompt/response content for notifications.
- Native Messaging runs through a local bridge, with origin/message checks and connection-state handling.
- Conversation titles shown in macOS notifications may remain visible in Notification Center.
- With optional ntfy publishing, event metadata is sent over HTTPS to the selected public `ntfy.sh` topic. Including chat titles is opt-in; a random topic name is **not authentication or end-to-end encryption**.
- Diagnostic summaries avoid exposing conversation text, IDs, and private notification content.

AgentPet is a companion for observing tasks, not a replacement for checking the actual Codex or ChatGPT application when the underlying event or metadata is ambiguous.
