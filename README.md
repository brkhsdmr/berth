# Berth

**A fixed-layout overview of your windows and virtual desktops, for macOS and Windows.**

Mission Control and Task View rearrange everything each time you open them. Berth doesn't: every app has its own place, its *berth*, and its windows always appear there with live previews. You find a window by where it lives, not by searching for it.

Free and open source (GPL-3.0). [Türkçe](README.tr.md)

![Berth on macOS: every app in its own place with live previews, the desktop strip at the top (window contents pixelated for this screenshot)](docs/images/scene.jpg)

## Features

- **Fixed places.** Pin apps to cells (small, medium or large); the layout stays the same every time. Apps you haven't pinned sit in a row at the bottom.
- **All desktops at once.** Windows from every virtual desktop and full-screen space, with a strip of desktops at the top.
- **Search.** Start typing to filter windows; matching apps appear in an icon grid under the search box, including apps that aren't running. Enter opens the best match.
- **Keyboard.** Arrow keys move between previews, Enter switches, ⌘1…9 / Ctrl+1…9 jumps to a desktop.
- **Window actions** right on the preview: snap left or right, fill the screen, minimize, close, and on macOS move to the next display.
- **Workspace layouts.** Save where every window is (desktop, position, size) and restore it later, with its own shortcut. Closed apps are launched for you.
- **Many ways to open.** Keyboard shortcut, a hot corner, the menu bar or tray icon, or a three- or four-finger swipe on a Mac trackpad.
- **Dock and taskbar previews.** Hover an icon to see that app's windows on every desktop.
- **Mac ↔ Windows bridge.** When you're connected to a Windows PC with Microsoft's Windows App (Remote Desktop), swiping up on the Mac trackpad opens Berth on that PC instead.
- **Private by design.** No account, no analytics, no network unless you turn on the Mac–Windows bridge. See [privacy](store/privacy.md).

<table><tr>
<td width="62%"><img src="docs/images/search.jpg" alt="Typing filters windows and shows matching apps in an icon grid, including apps that are not running"></td>
<td><img src="docs/images/dock-preview.png" alt="Hovering a Dock icon shows that app's windows on every desktop"></td>
</tr></table>

<details>
<summary>More screenshots: settings</summary>

| | |
|---|---|
| ![Opening: shortcut, trackpad gesture, hot corner](docs/images/settings-opening.png) | ![Pinned apps](docs/images/settings-pinned.png) |
| ![Workspace layouts](docs/images/settings-layouts.png) | ![Windows connection](docs/images/settings-windows.png) |
| ![General](docs/images/settings-general.png) | ![Permissions](docs/images/settings-permissions.png) |

</details>

## Requirements

| | macOS | Windows |
|---|---|---|
| Version | macOS 14 or later | Windows 11 |
| Permissions | Accessibility (switching and moving windows); Screen Recording is optional (live previews) | none |
| Interface | English and Turkish | English and Turkish |

## Install

Signed downloads will be on the [Releases](https://github.com/brkhsdmr/berth/releases) page, and Berth for Windows on the Microsoft Store. Until then, build from source.

### macOS

```bash
./Scripts/make-app.sh release    # builds, signs with your Apple Development identity, installs to /Applications
swift test                       # core layout tests
```

Open with ⌥⇧Space or the menu bar icon.

### Windows

Needs Visual Studio 2022 or later with the "Desktop development with C++" workload (Build Tools is enough).

```powershell
windows\scripts\build.ps1 Release
windows\scripts\install.ps1
```

Open with Alt+Shift+Space or the tray icon.

## How it works

Berth is native on both platforms: Swift and AppKit with Core Animation on macOS, C++ and Win32 with Direct2D and DWM thumbnails on Windows. The layout rules (cell placement, piles, search ranking, layout matching) live in a platform-independent core with unit tests on each side: `Sources/BerthCore` and `windows/src/core`.

Some of what Berth does has no public API, so it relies on undocumented system interfaces. These are isolated, looked up at run time, and fail softly:

- **macOS:** SkyLight for the list of spaces and which window is on which, MultitouchSupport to tell three fingers from four. If an update removes them, the desktop strip or finger detection stops working and the rest of the app keeps going. Settings > Permissions shows a compatibility check.
- **Windows:** the internal virtual desktop interface (`IVirtualDesktopManagerInternal`), whose identifiers change between Windows releases.

Engineering notes, with the measurements behind each decision, are in [docs/mac-notes.md](docs/mac-notes.md) and [docs/windows-notes.md](docs/windows-notes.md) (Turkish). Release steps are in [docs/distribution.md](docs/distribution.md).

## Project layout

```
Sources/BerthCore      layout rules, no AppKit, unit tested
Sources/Berth          macOS app
Tests/BerthCoreTests   core tests
windows/src/core       layout rules for Windows, unit tested
windows/src/app        Windows app
windows/packaging      installer and Store package
store                  Store listing and privacy policy
docs                   engineering notes and release steps
```

## About

Built by [Burak Hasdemir](https://github.com/brkhsdmr). Berth was designed and directed by me and written with [Claude](https://claude.com/claude-code), Anthropic's AI coding assistant, through a long back-and-forth of ideas, measurements and testing on real machines.

Issues and pull requests are welcome.

## License

[GPL-3.0](LICENSE). You're free to use, study, change and share Berth; if you distribute a modified version, its source must stay open under the same license.

"Mission Control" is a trademark of Apple Inc. Berth is not affiliated with Apple or Microsoft.
