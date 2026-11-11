# Changelog

Also shown in the app: **Settings › Versions**.

## 4.1.4

- Display blackout (⌘⇧<) removed: it caused problems on some systems

## 4.1.3

- Simpler Mouse page: descriptions and tooltips removed, the pointer location setting is gone

## 4.1.2

- Fix: device-specific settings weren't applied to mice that don't report a serial number (most Bluetooth mice)
- Fix: in Turkish, the Mouse page didn't fit the window and shifted sideways

## 4.1.1

- Mouse now has its own page in Settings (Mouse in the sidebar)
- Fix: smooth scrolling and button settings didn't work while Missing was in the background
- Pointer settings apply without Accessibility permission too, and are written again after sleep
- Mouse imports settings from other mouse apps by itself the first time you turn it on

## 4.1.0

- New Mouse window: no separate mouse app needed (open it from the menu or Settings › Features)
- Smooth scrolling: step, speed gain and duration; trackpad-style scrolling; separate smoothing and reverse for vertical and horizontal
- Scrolling modes (accelerated, lines, pixels) that work with smoothing; keys that speed up, switch direction or turn off smoothing while held
- Pointer: turn off acceleration, separate acceleration and speed; returns to the system setting when Missing quits or crashes
- Buttons: universal back/forward, left↔right switch, click debouncing, middle-button autoscroll, gestures, button mappings and actions
- Every setting can apply to all mice, one device, one display or one app; settings from other mouse apps can be imported

## 4.0.0

- Missing 4.0: the features the Mac left out, now a complete set
- New Versions page: your version in a red box, the rest as cards; tap one for all its notes
- The selected card in ⌘Tab is highlighted in Missing red
- Settings reorganized: the equalizer moved to Quick Features, battery and charging profiles have their own page (14-inch MacBook Pro M4 Pro only)

## 3.0.8

- Battery and charging profiles: switching from the menu changes the power mode too (set up once in Settings › Screen)

## 3.0.7

- Equalizer: 10 bands and a preamp (dB) for system audio, with presets; no extra app needed (Settings › Sound, macOS 14.2+)

## 3.0.6

- MacBook Pro 14" M4 Pro: unplugged drops the display to 600 nits and 60 Hz with Low Power; plugged in returns to 1600 nits, ProMotion and High Power (Settings › Screen, button in the menu)
- Finder tabs use Finder's own bar material and no longer vanish on right-click
- Area and window screenshots now show the preview card in the bottom right too

## 3.0.5

- Typing in Finder's search box shows Missing's instant results right below it (↓↑ ↩ ⌘↩ Esc)
- Finder tabs stay put: they no longer vanish on right-click or reappear when switching apps; the colour is sampled correctly from Finder
- Choose folders for window screenshots and window recordings (Settings › Screen)

## 3.0.4

- Finder's search box and ⌘F open Missing's search too
- Videos no longer autoplay in the search preview; search stays open after closing Quick Look with Space
- Capture just a window: pick a single window for screenshots or recordings (⌘⇧5 palette)
- Split screen: fill zones with that screen's most recent windows automatically, or choose them yourself (Settings › Screen)
- Finder tabs: × always closes, the strip slides in from the top and matches Finder's colour

## 3.0.3

- File search: the selected result is previewed on the right; hover to preview, Space opens Quick Look like in Finder
- Delete right from search: ⌘⌫ or the trash button moves the file to the Trash and the row disappears at once
- The folder token sits next to the magnifier with the real folder icon; a shortcut bar runs along the bottom
- Windows-style Finder tabs: a set width that shrinks as you add more and scrolls when they don't fit (Quick Features)

## 3.0.2

- The Features panel now turns whole tabs on or off: Window Switcher, Sound, Screen, Quick Features. A tab you turn off leaves the sidebar and the menu bar panel, and nothing in it runs
- Turn a tab back on and its settings return as they were; every option inside a tab has its own switch

## 3.0.1

- Features panel: the main shortcuts (⌘Tab, sound, screenshots, split screen) with live previews in one place; anything you turn off disappears from Settings, the menu bar panel and the shortcut list
- Suggest a Feature: tell us what your Mac is missing on GitHub (Settings › Suggest a Feature)
- ⌘Tab: keys no longer wait while the window list is prepared; windows that don't fit scroll into view
- Notch island: your two most-used layouts sit right under the notch
- Full Disk Access is detected correctly; ⌘Space opens file search only while Finder is active

## 3.0.0

- AudioTab is now Missing: the features the Mac left out, in one app
- New settings: sidebar, collapsible cards, an on/off switch for every feature
- Quick Features: grouped view, Finder mouse buttons, Dock drag and drop, always find windows, file search and monitor blackout in one place
- Shortcuts page: every shortcut shows what it does with an animation
- File search looks like Spotlight and opens with ⌘Space only while Finder is in front
- New glass panel in the menu bar: sound output, quick actions, displays
- The notch tiling island now shows a live preview under the notch
- Drop a file on an app in the ⌘Tab panel to open it there (drop on a Finder window to move it into that folder)
- Features you turn off never ask for permissions; first launch asks what you'll use
