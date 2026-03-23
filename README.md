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
- for live mode: Windsurf should be running

## How it works

The app uses two local data sources:

1. live data from the running Windsurf language server
2. cached quota data from `~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb`

The app prefers live data when possible and falls back to cached local state when Windsurf is not running or the live request fails.

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
git clone https://github.com/adntgv/claude-usage-systray
cd claude-usage-systray/claude-usage-systray
xcodebuild -scheme ClaudeUsageSystray -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/ClaudeUsageSystray-*/Build/Products/Release/ClaudeUsageSystray.app
```

Or open `ClaudeUsageSystray.xcodeproj` in Xcode and run with ⌘R.

## Running tests

```bash
xcodebuild test -project ClaudeUsageSystray.xcodeproj \
  -scheme ClaudeUsageSystrayTests \
  -destination 'platform=macOS'
```

## Status

The app behavior is already Windsurf-oriented, but some project-level names still use the historical `ClaudeUsageSystray` identifiers.

## License

MIT
