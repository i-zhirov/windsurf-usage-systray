# Windsurf Usage Systray

A lightweight macOS menu bar app that shows your Windsurf quota without opening the editor or a browser.

![Windsurf Usage Systray](claude-usage-systray/Resources/Assets.xcassets/Image.imageset/Image.png)

## What it shows

The app focuses on the Windsurf quota model:

| Metric | Description |
|--------|-------------|
| **Daily** | Remaining daily quota percentage |
| **Weekly** | Remaining weekly quota percentage |
| **Plan** | Current Windsurf plan when available |
| **Source** | Whether the app is showing live or cached data |

Colors update from your configured warning and critical thresholds.

## Requirements

- macOS 13+
- Windsurf installed
- Apple Silicon and Intel Macs are supported
- for live mode: Windsurf should be running

## How it works

The app uses two local data sources:

1. live data from the running Windsurf language server
2. cached quota data from `~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb`

The app prefers live data when possible and falls back to cached local state when Windsurf is not running or the live request fails.

Windsurf requires a dual-source local-first design because of lack of public API for remaining quota and live quota is best obtained from the authenticated local language server, while cached local state provides a safe fallback.

For live mode discovery, the app supports both macOS Windsurf language server variants:

- `language_server_macos_arm`
- `language_server_macos_x64`

## Display modes

Toggle **Compact display** in Settings to switch between:

- **Compact (default):** `D88 · W49`
- **Normal:** icon + weekly remaining percentage

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Prefer live Windsurf data | On | Use the local Windsurf language server first |
| Show source in popover | On | Show whether data is live or cached |
| Compact display | On | Show daily and weekly quota in the menu bar |
| Warning threshold | 80% | Orange when weekly used quota crosses this |
| Critical threshold | 90% | Red when weekly used quota crosses this |
| Quota alerts | On | macOS notification when thresholds are crossed |

## Build from source

```bash
git clone https://github.com/i-zhirov/claude-usage-systray
cd claude-usage-systray/claude-usage-systray
xcodebuild -project WindsurfUsageSystray.xcodeproj -scheme WindsurfUsageSystray -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/WindsurfUsageSystray-*/Build/Products/Release/WindsurfUsageSystray.app
```

Or open `WindsurfUsageSystray.xcodeproj` in Xcode and run with ⌘R.

## Running tests

```bash
xcodebuild test -project WindsurfUsageSystray.xcodeproj \
  -scheme WindsurfUsageSystrayTests \
  -destination 'platform=macOS'
```

## Status

The app behavior is already Windsurf-oriented.

The repository directory name is still historical, but the project, schemes, bundle identifiers, artifacts, and release metadata now use `WindsurfUsageSystray`.

## License

MIT
