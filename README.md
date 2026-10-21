# AgentPet

AgentPet is a native macOS menu bar companion for Codex. A yellow pixel chick wearing an eggshell cap works at a tiny blue laptop, reacts to observed Codex lifecycle events, and displays real usage information.

Built with SwiftUI and AppKit. The app includes five energy atlases, 30 animation states, 38 transitions, a transparent floating pet window, and a compact two-bar usage HUD.

## Features

- Tracks observed Codex `UserPromptSubmit`, `Stop`, `PermissionRequest`, and `Interrupt` events.
- Shows a numeric bubble for observed Running sessions.
- Displays Codex's 5H and 7D remaining usage; the 5H window controls the pet's energy tier.
- Provides idle activities, hover and click reactions, drag and drop, and a dashboard.
- Uses Sparkle 2 for signed application updates.
- Includes a native Swift hook collector; Python is not required.

Task status is evidence based. A historical thread is not considered Running, `Stop` means a turn ended rather than succeeded, and a permission request event does not confirm that approval is still pending. If event continuity is lost, affected live sessions become Unknown.

## Requirements

To run AgentPet:

- macOS 14 or later.
- ChatGPT Desktop with its bundled Codex App Server for Codex integration.

To build AgentPet:

- Xcode 16 or later with Swift 6 support.
- Internet access to resolve the Sparkle package.

The distributed app does not require Python, Homebrew, Node.js, Docker, or Xcode.

## Installation

1. Download the latest `AgentPet-X.Y.Z.dmg` from [GitHub Releases](https://github.com/honvan8325/AgentPet/releases/latest).
2. Open the DMG and drag `AgentPet.app` to Applications.
3. Launch AgentPet. Its menu bar icon and floating pet should appear.

AgentPet is distributed with ad-hoc code signing and is not notarized. If macOS blocks the app, open **System Settings → Privacy & Security**, review the AgentPet message, and choose **Open Anyway** when available. You may need to try launching it again. Do not disable Gatekeeper globally.

## First use

1. Select **Enable Codex Integration** from the menu bar, dashboard, or Settings.
2. Review and trust AgentPet's four lifecycle handlers in ChatGPT Desktop's Codex Hooks interface.
3. Reload ChatGPT if its hooks interface requests it. AgentPet does not restart ChatGPT.
4. Submit a new Codex prompt after AgentPet is running.

AgentPet preserves other applications' hook handlers. If an older AgentPet Python command is present, the app offers **Repair Codex Integration** to migrate it to the native collector. **Retry Live Tracking** restarts the event reader without rewriting `~/.codex/hooks.json`.

A task that started before AgentPet began observing events may not appear as active. App Server thread history does not establish live runtime state.

## Menu bar, pet, and dashboard

The menu bar provides:

- Show or hide the pet.
- Open Dashboard.
- Enable, disable, repair, or retry Codex integration as appropriate.
- Launch at Login.
- Open Settings.
- Check for Updates.
- Quit AgentPet.

Drag the chick to move it; its position is saved. Right-click the pet for its context menu. Clicking the pet plays an animation and does not open the dashboard.

The dashboard shows Codex connection status, 5H/7D usage, observed Running sessions, permission request events, recent threads, task status, source, and update time. A row opens its Codex thread only when AgentPet has a validated thread ID. Historical threads are shown with Unknown runtime state.

The compact HUD contains two unlabeled bars. The thought bubble counts observed Running sessions and disappears when the count is zero. Unavailable usage appears as an empty neutral bar rather than 0% remaining.

## Settings

Settings includes:

- Pet size, HUD visibility, pause, and appearance.
- Launch at Login.
- Current version and Sparkle update controls.
- Codex integration status and enable/disable/repair/retry actions.

Pausing AgentPet affects its animation only; it does not pause Codex tasks.

## Codex integration and privacy

AgentPet finds ChatGPT Desktop through LaunchServices and starts its bundled Codex CLI as an AgentPet-owned App Server subprocess. It reads rate limits, recent thread metadata, and individual thread metadata when needed. It does not infer Running status from thread history or read full conversations.

The native `AgentPetHook` collector is installed at:

```text
~/Library/Application Support/AgentPet/bin/AgentPetHook
```

It writes event name, session ID, turn ID, sequence, and timestamp to:

```text
~/Library/Application Support/AgentPet/events.jsonl
```

The log is bounded. The collector does not write prompts, responses, transcripts, or source code. A continuity marker records lost events so AgentPet can stop presenting affected sessions as live.

## Updates

Sparkle checks the signed appcast hosted through GitHub Pages and downloads release archives from GitHub Releases. Automatic update checks are enabled by default; automatic downloads are optional. Sparkle verifies update archives with EdDSA. This is separate from Apple's Developer ID signing and notarization.

Use **Check for Updates…** in the menu bar or Settings to check manually. A development build may not have the release feed URL or public key configured.

## Build from source

```sh
xcodebuild \
  -project AgentPet.xcodeproj \
  -scheme AgentPet \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY=- \
  build
```

The project has two targets: the macOS app and the native `AgentPetHook` helper. Sparkle is resolved through Swift Package Manager.

## GitHub releases

The workflow at `.github/workflows/release.yml` runs only for version tags matching `v*` and validates semantic version tags before building. A release packages:

- `AgentPet-X.Y.Z.dmg` for initial installation.
- `AgentPet-X.Y.Z.zip` for Sparkle.
- `SHA256SUMS.txt`.

It signs and verifies the Sparkle appcast, publishes the GitHub Release, and deploys `appcast.xml` through GitHub Pages. Repository Actions configuration requires the `SPARKLE_PRIVATE_KEY` secret and matching `SPARKLE_PUBLIC_ED_KEY` variable. Keep the private key out of the repository and CI logs. Published tags and release archives should remain immutable.

## Troubleshooting

**Live tracking is configured but no event has arrived:** trust the handlers in Codex, reload ChatGPT if requested, and submit a new prompt after AgentPet starts.

**Integration needs repair:** use **Repair Codex Integration** to replace recognized legacy or partial AgentPet handlers while preserving unrelated handlers.

**Reader error with native handlers configured:** use **Retry Live Tracking**. This restarts local log reading without rewriting the hooks configuration.

**Codex is connected but a task is Unknown:** connection and lifecycle tracking are separate. Historical thread metadata cannot establish current runtime state.

**Usage is unavailable:** ensure ChatGPT Desktop and its bundled Codex App Server are available, then refresh the dashboard. AgentPet clears quota data it can no longer confirm.

**GitHub Pages rejects a release deployment:** check the `github-pages` environment's deployment rules for version tags. This is a repository configuration issue, not a reason to replace the Sparkle keypair.

## Uninstall

1. Disable Codex Integration in the menu bar, dashboard, or Settings.
2. Reload ChatGPT if needed to apply its updated hook configuration.
3. Disable Launch at Login if enabled, quit AgentPet, and remove `AgentPet.app` from Applications.
4. Optionally delete `~/Library/Application Support/AgentPet/` to remove AgentPet's collector and event log.

## Contributing

Bug reports and pull requests are welcome through [GitHub Issues](https://github.com/honvan8325/AgentPet/issues) and [GitHub Pull Requests](https://github.com/honvan8325/AgentPet/pulls). Include your macOS and AgentPet versions, reproduction steps, and relevant non-sensitive errors. Do not post credentials, signing keys, or private Codex content.
