# FastSome

A lightweight macOS launcher for your favorite apps, files, and folders.

Open the same panel from the **menu bar**, the **Dock**, or a **global hotkey**. Organize items into groups, pick a layout in Settings, and launch with a click or `⌘` + number.

## Requirements

- macOS 14+
- Xcode 15+ (to build from source)

## Build

```bash
open FastSome.xcodeproj
```

Select the **FastSome** scheme and run (⌘R), or from the terminal:

```bash
xcodebuild -project FastSome.xcodeproj -scheme FastSome -configuration Debug -destination 'platform=macOS' build
xcodebuild -project FastSome.xcodeproj -scheme FastSome -destination 'platform=macOS' test
```

Built app (after Debug build): look under Xcode DerivedData, or run from Xcode.

## Features (v1)

- Menu bar icon + global hotkey to show/hide the panel (anchored under the menu bar icon; no Dock launcher)
- Groups of app / file / folder shortcuts
- Layouts: top tabs + grid, sidebar + grid, or list
- Edit mode: add/remove, reorder, drag onto a group name to move, rename group via dialog
- Settings: layout, global hotkey, launch at login
- Hold `⌘` to reveal number hints; `⌘1`–`⌘9` / `⌘0` open items 1–10
- Panel closes after launching an item

## License

License TBD (will be added before publishing to GitHub).
