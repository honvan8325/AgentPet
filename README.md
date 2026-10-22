# AgentPet

AgentPet is a native macOS menu bar companion for Codex. Its animated Chick sits on the desktop, reflects available Codex usage, and responds to live lifecycle events.

## Features

- Displays 5-hour and 7-day Codex usage independently. When only weekly usage is available, the pet uses 7-day usage for its energy state and shows the weekly HUD bar.
- Shows a task bubble only while AgentPet has observed a running Codex session.
- Animates across energy states, moods, work, idle behavior, and user interactions.
- Includes a Dashboard for usage, active and recent threads, integration status, and diagnostics.
- Offers optional notifications for turn events, observed permission requests, and low quota.
- Preserves screen position and supports configurable pet size, HUD visibility, appearance, motion, and desktop behavior.

## Requirements

- macOS 14 or later.
- ChatGPT Desktop with its bundled Codex CLI for Codex App Server usage and thread metadata.
- Xcode 16 or later with Swift 6 support to build from source.

## Install and set up

1. Download the latest DMG from [GitHub Releases](https://github.com/honvan8325/AgentPet/releases/latest), open it, and move `AgentPet.app` to Applications.
2. Launch AgentPet and complete the first-run setup.
3. Enable Codex Integration in the app. AgentPet installs its native hook collector and adds its lifecycle handlers to `~/.codex/hooks.json` while preserving unrelated handlers.
4. Review and trust AgentPet's handlers in Codex. Reload Codex if requested, then start a new task so AgentPet can observe its events.
5. Enable notifications in Settings if desired. macOS permission is requested when notifications are enabled.

AgentPet remains available when Codex is disconnected. Releases are ad hoc signed and are not notarized by Apple. macOS may show a security warning the first time the app is opened; download it from the official release page and allow it only if you trust the source.

## Usage and task status

The Dashboard shows available quota windows, reset times when provided, the Codex connection, active tasks, recent threads, hook status, and diagnostics. Use **Reconnect Codex** to restart the App Server connection or **Retry Live Tracking** to resume reading hook events without rewriting the hooks configuration.

Live task status comes from lifecycle events, not from thread history. Tasks that were already running before tracking started may be shown as Unknown. A `Stop` event means a turn ended; it does not indicate whether the turn succeeded. A permission request is an observation and may no longer be pending. The task bubble is hidden when no sessions are confirmed Running.

The pet's energy uses the 5-hour usage window when available, falling back to the 7-day window. Missing quota is treated as unavailable, not as zero remaining. The HUD shows only available usage windows.

## Settings

Settings lets you choose the mascot and size, show or hide the usage HUD, keep the pet on top or within the visible screen area, reduce motion, pause the pet's animation, select an appearance, configure notifications, launch at login, and manage Codex integration and Sparkle updates. Pet sizes are Small (1.25×), Medium (1.75×), and Large (2.5×). Pausing AgentPet does not pause Codex tasks.

Only the Chick mascot is currently bundled. Right-click the pet to open the Dashboard or Settings; clicking the pet plays a reaction.

## Asset system

Chick uses Asset System V3: 88 animation clips, 30 energy and mood variants per clip, individually timed frames, and 308 atlas pages. Each source frame is 64×64 pixels and is rendered at 128×128 with nearest-neighbor scaling. Atlas pages are decoded on demand, with at most eight pages held in memory.

The app discovers compatible themes from V3 manifests under `AgentPet/Resources/Themes/`. Chick is the only theme currently included. Runtime assets are kept in `AgentPet/Resources/Themes/chick/`; editable source animation frames and asset-generation tools are not included in this repository or the app bundle.

## Build from source

Xcode resolves Sparkle through Swift Package Manager, so package resolution requires network access.

```sh
xcodebuild \
  -resolvePackageDependencies \
  -project AgentPet.xcodeproj \
  -scheme AgentPet

xcodebuild \
  -project AgentPet.xcodeproj \
  -scheme AgentPet \
  -configuration Debug \
  CODE_SIGN_IDENTITY=- \
  build
```

The Xcode project builds the macOS app and the native `AgentPetHook` helper.

## Releases

Pushing a semantic version tag in the form `vMAJOR.MINOR.PATCH` starts the GitHub Actions release workflow. It validates the Chick V3 resources, builds an Apple silicon app, creates a DMG, a Sparkle ZIP, and SHA-256 checksums, then publishes the GitHub Release and Sparkle appcast.

The workflow requires the `SPARKLE_PRIVATE_KEY` repository secret and a matching `SPARKLE_PUBLIC_ED_KEY` repository variable. Sparkle's EdDSA update signature is separate from Apple's code signing. Release builds use ad hoc signing and are not notarized.

## Privacy

AgentPet starts the Codex App Server bundled with ChatGPT Desktop and reads usage and thread metadata. Its native hook collector records lifecycle event names, session IDs, turn IDs, sequence numbers, and timestamps in `~/Library/Application Support/AgentPet/events.jsonl`. It does not record prompts, responses, transcripts, or source code. Diagnostics omit session identifiers and conversation content.

AgentPet does not infer live task status from historical threads. If event continuity is lost, affected sessions are no longer presented as confirmed live tasks.
