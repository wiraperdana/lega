# Lega

A one-button storage cleaner for Mac. Lega removes caches that rebuild themselves, then shows other large items you can clean up after confirming.

*English · [Bahasa Indonesia](README.id.md)*

An open-source product from [InnovationKit](https://wiraperdana.com), released under the MIT license.

## Download

Get the DMG from [lega.wiraperdana.com](https://lega.wiraperdana.com/#download):

- [Lega for Apple Silicon](https://lega.wiraperdana.com/download/Lega-1.0.0-AppleSilicon.dmg) (M1 and later)
- [Lega for Intel](https://lega.wiraperdana.com/download/Lega-1.0.0-Intel.dmg)

Open the DMG and drag Lega to Applications. Lega is not yet signed with an Apple Developer ID, so macOS blocks it the first time. Open System Settings, Privacy & Security, then click Open Anyway. You only need to do this once.

## Features

- **One-button quick clean.** Browser caches (including Arc, Chrome, and Comet Service Workers), Zoom, Homebrew, npm, pip, uv, Go, node-gyp, Clang and Swift compiler caches, pending update downloads, and old Codex versions.
- **Safe with open apps.** Caches of apps that are still running are skipped, so you don't need to restart your Mac.
- **Advanced options with confirmation.** WhatsApp media, Claude Desktop VM, Office AutoRecovery files, Playwright browsers, Trash, orphaned Microsoft AutoUpdate, and the largest items in Downloads.
- **Largest Applications.** The twelve largest apps, which you can move to Trash after confirming.
- **Restart suggestion.** Appears when disk swap exceeds 2 GB or your Mac has been on for three days.
- **English and Bahasa Indonesia.** English by default, switchable in Settings.
- **Two layouts.** Sidebar or single page, with light, dark, or system appearance.
- **Menu bar.** See free space and clean caches without opening a window.
- **Runs at login.** Can be turned off in Settings.
- **Logged.** Every clean is written to `~/Library/Logs/Lega.log`.

## Safety principles

1. Only caches that rebuild themselves, and data that can be downloaded again, are deleted permanently.
2. Your own files, such as Downloads and AutoRecovery, are moved to Trash, so you can restore them.
3. Data of apps with their own database, such as WhatsApp, is never deleted directly. Lega only opens the app.
4. Microsoft AutoUpdate can only be removed when no Microsoft app is installed anymore.

## Requirements

- macOS 15 Sequoia or later
- Apple Silicon or Intel (universal build)
- Command Line Tools for Xcode, to build from source: `xcode-select --install`

## Build and install

```bash
git clone https://github.com/wiraperdana/lega.git
cd lega
./build.sh
```

This script compiles the app for Apple Silicon and Intel, then installs it to `~/Applications`. Use `./build.sh --no-install` to build only.

The built app is signed locally (ad-hoc), without an Apple Developer ID. It works right away on the Mac where you built it. If you copy the `.app` to another Mac, Gatekeeper blocks it the first time. Open System Settings, Privacy & Security, then click Open Anyway.

To make the Apple Silicon and Intel DMGs, run `./build.sh --no-install` then `Scripts/make-dmg.sh`. The output goes to `build/dmg/`.

## Permissions macOS will ask for

| Permission | When | Why |
|---|---|---|
| Downloads folder access | First scan | To list the largest items |
| Finder control (Automation) | When emptying Trash | Finder empties the Trash |
| Admin password | When removing Microsoft AutoUpdate | Its files live in a system folder |
| Login item | First launch | To run when your Mac starts |

## Adding a clean target

The quick-clean list is the `quickTargets` array in `Sources/main.swift`. A target has a name, paths, an SF Symbol icon, and the apps that must be closed first:

```swift
CacheTarget(id: "slack", name: "Cache Slack", note: "Dibuat ulang saat Slack dipakai",
            icon: "bubble.left", paths: ["~/Library/Caches/com.tinyspeck.slackmacgap"], blockers: ["Slack"]),
```

Only add folders that are truly caches. When in doubt, make it an advanced option with confirmation.

## Structure

| Path | Contents |
|---|---|
| `Sources/main.swift` | The whole SwiftUI app |
| `Scripts/make-icon.swift` | Draws the icon into `Resources/AppIcon.icns` |
| `build.sh` | Universal build, ad-hoc signing, and install |
| `Scripts/make-dmg.sh` | Separate DMGs for Apple Silicon and Intel |
| `docs/` | The lega.wiraperdana.com landing page, served by GitHub Pages |

## License

MIT. See [LICENSE](LICENSE).
