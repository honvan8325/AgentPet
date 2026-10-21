# AgentPet

AgentPet is a native macOS menu bar companion for Codex. Its yellow pixel chick wears an eggshell cap and uses a mini laptop across five sprite atlases, with 30 animation states and 38 transitions.

## Requirements

- macOS 14 or later
- Xcode 16 or later and Swift 6 to build from source
- ChatGPT Desktop with its bundled Codex App Server for Codex integration

## Installation

Download the latest DMG from the repository's **Releases** page, open it, and drag `AgentPet.app` to `Applications`.

This app is ad-hoc signed and is not notarized by Apple. If macOS blocks it, open **System Settings → Privacy & Security** and choose **Open Anyway** only if you trust the copy you downloaded. Sparkle update archives use separate EdDSA signatures; those signatures do not notarize the app or identify its developer to Gatekeeper.

## Build and run

Open `AgentPet.xcodeproj`, select the `AgentPet` scheme, and run it from Xcode. Or build from the workspace root:

```sh
xcodebuild -project AgentPet.xcodeproj -scheme AgentPet -configuration Debug \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/AgentPet" \
  CODE_SIGN_IDENTITY=- build
```

The app and native lifecycle collector use Swift 6. The pet and menu bar item appear without a Dock icon. The bundled Sparkle framework and collector require no separate installation by end users.

## Pet behavior

- The unlabeled pixel usage bars follow the real 5H remaining quota.
- The thought bubble shows the count of sessions currently Running and disappears when the count is zero.
- Clicking, double-clicking, hovering, dragging, and idle animations stay within the existing pet behavior.
- `Approval requested` means a permission request was observed; it does not confirm approval is still pending. `Ready` means a turn ended, not that it succeeded. `Unknown runtime state` means AgentPet cannot confirm the current turn state.

## Codex integration

Choose **Enable Codex Integration** in the menu bar or dashboard. Review and trust AgentPet's four lifecycle handlers in Codex's official hooks screen. ChatGPT may request a reload; AgentPet does not restart ChatGPT. Choose **Disable Codex Integration** to remove only AgentPet's exact handlers from `~/.codex/hooks.json`.

The native Swift collector writes event names, session IDs, turn IDs, sequence numbers, and timestamps to `~/Library/Application Support/AgentPet/events.jsonl`. It does not store prompts, responses, or transcripts and does not require Python. When the app starts, it installs or updates the bundled collector at `~/Library/Application Support/AgentPet/bin/AgentPetHook`; hooks keep this stable path after app updates.

When enabling or repairing an older installation, AgentPet replaces only its exact Python hook commands with the native collector and preserves other applications' handlers. The previous `hook.py` may remain in Application Support so a running ChatGPT process can finish using a cached command. After ChatGPT has reloaded the updated hooks, it can be removed. Hook trust is always managed by Codex's official UI.

The collector and reader share a file lock. The log is bounded, and any discarded events invalidate live statuses to `Unknown runtime state`.

## Updating

Choose **Check for Updates…** from the menu bar or Settings. Sparkle checks the HTTPS GitHub Pages appcast once a day by default. **Automatically check for updates** is enabled by default; **Automatically download and install updates** is optional and disabled by default. Sparkle verifies every update archive with EdDSA before installation.

The release workflow derives the appcast URL from the GitHub repository name and publishes `appcast.xml` through GitHub Pages. Project Pages use `https://<owner>.github.io/<repository>/appcast.xml`; a `<owner>.github.io` repository uses `https://<owner>.github.io/appcast.xml`.

## Releasing

Push a SemVer tag to create a Release:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The tag is the Release version source. GitHub Actions validates it, builds an arm64 ad-hoc signed app, creates the drag-and-drop DMG, Sparkle ZIP, and SHA-256 checksums, signs the appcast with Sparkle's EdDSA tool, creates the GitHub Release, then deploys the feed to GitHub Pages. Pushes without a `vMAJOR.MINOR.PATCH` tag do not create a Release. Re-running a released tag reuses its existing archives and never overwrites them.

### Initial maintainer setup

1. In repository **Settings → Pages → Build and deployment**, set **Source** to **GitHub Actions**.
2. Resolve the Sparkle package, then run its `generate_keys` tool once. Keep the private key in the maintainer's Keychain. Use Sparkle's supported export option only when transferring it to GitHub Actions.
3. Add the public key as the repository Actions variable `SPARKLE_PUBLIC_ED_KEY` and the exported private key as the Actions secret `SPARKLE_PRIVATE_KEY`. Keep the private key out of the repository and logs. The workflow fails before publishing if either key is missing.
4. Do not replace the keypair after a release without following Sparkle's key-rotation process.

No Apple Developer ID, paid Apple account, or notarization is required. GitHub Pages setup and the Sparkle keypair are one-time maintainer steps.

## Uninstall

Disable Codex integration, wait until ChatGPT has reloaded its hook configuration, and remove AgentPet from Applications. Remove its login item from AgentPet Settings if enabled. Remove `~/Library/Application Support/AgentPet/` if you also want to delete the native collector and lifecycle log.
