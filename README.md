<div align="center">

<img src="design/AppIcon1024.png" alt="Missing" width="128">

# Missing

**The features your Mac left out, in one light menu bar app.**

[**Download**](https://github.com/firewallstudio/Missing/releases/latest) · [Install](#install) · [Shortcuts](#shortcuts) · [**Türkçe**](README.tr.md)

</div>

---

The Mac is great, but some everyday things are missing or only half done. ⌘Tab shows apps, not windows. Switching the sound output takes a trip through menus. Splitting the screen, capturing a long page or finding a file by name each mean hunting for another app.

Missing puts these forgotten features in one place, and each one feels like part of macOS. Turn off what you don't need: a feature you turn off never asks for a permission and never runs.

## Features

| | |
|---|---|
| **⌘Tab, window by window** | Windows, not just apps, with live previews. Every browser profile, every Space, full-screen windows too. Drop a file on a card to open it with that app. |
| **One-key sound output** | Hold ⌘ and tap ⇧: speakers → headphones → monitor. Assign a device per app. |
| **Split screen** | ⌘< or drag a window to the top of the screen (on MacBooks, to the notch) and pick a layout. |
| **Screenshots and recording** | ⌘⇧3 for the display you're on, ⌘⇧4 for an area, ⌘⇧6 for scrolling pages, ⌘⇧5 to record MP4. |
| **File search in Finder** | ⌘Space while Finder is in front: a Spotlight-style bar that searches file names instantly, inside the folder you're in. |
| **Quick features** | Grouped ⌘Tab view, mouse back/forward in Finder, Dock drag and drop, black out every display with ⌘⇧<. |

It does nothing while idle and only goes online to check for updates. Native Swift.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/firewallstudio/Missing/main/install.sh | bash
```

Or download `Missing.zip` from [Releases](https://github.com/firewallstudio/Missing/releases/latest) and drag `Missing.app` into **Applications**.

On first launch Missing asks which features you want and only requests the permissions those need. You can change everything later in **Settings**.

Missing isn't in Apple's paid developer program. If you downloaded the zip in a browser and macOS blocks it, open **System Settings › Privacy & Security** and click **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Missing.app`.

## Shortcuts

| Shortcut | Does |
|---|---|
| ⌘Tab / ⌥Tab | Switch windows (⌥Tab with previews) |
| ⌘⇧ (tap ⇧) | Next sound output |
| ⌘< | Split screen |
| ⌘⇧3 · ⌘⇧4 · ⌘⇧5 · ⌘⇧6 | Display · area · record · scrolling capture |
| ⌘Space (in Finder) | Find files |
| ⌘⇧< | Black out displays |

**Settings › Shortcuts** shows each one in action.

## Build

```bash
./build.sh             # build Missing.app for this Mac
./build.sh --install   # build and install to /Applications
```

Every release is signed with the same certificate (`signing/AudioTab.pem`), so macOS keeps your permissions across updates and the updater only installs builds signed with it.
