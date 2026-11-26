# Changelog

Also shown in the app: **Settings › Versions**.

## 4.3.25

- New: Volume leveler. Raises quiet sound and lowers loud sound so everything from the computer plays at the level you pick (Settings › Quick Features, or the menu bar panel)
- Silence and pauses between sentences aren't boosted, sudden loud sounds are lowered without clipping; it shares the equalizer's audio path and uses next to no CPU

## 4.3.24

- ⌘Tab no longer stutters when switching to or from Chrome: Chrome's pop-up bubbles (like "Restore pages?") are no longer listed as windows
- Type to select in Files: typing "m", "mi", "mis" selects the first item whose name starts with it, in icon and list views
- Files' right-click menu now responds to the first click (it needed two)

## 4.3.23

- Missing is now signed with its own certificate (Missing Code Signing). Coming from 4.3.22 or earlier needs one manual download, and macOS asks for Missing's permissions (Accessibility, Screen Recording…) once more
- Everything from 4.3.22 below (4.3.22 itself was never published)

## 4.3.22

- Files has its own context menu: glass background, icons, shortcuts and submenus that open to the side
- Quick Actions by file type: rotate / convert / resize images, images to PDF, combine PDFs or turn pages into images, convert / shrink video, extract audio, convert audio
- Get Info (⌘I), Compress / Extract Here, Make Alias, Show Original, Show Package Contents, iCloud Download Now / Remove Download
- Trash and Network now open inside Files: the Trash can be emptied, and the Network page finds computers sharing files and connects to servers
- Recents in the sidebar, folder sizes in list view, folders that open when you hover while dragging, Recent Folders in the Dock menu
- All four themes follow the macOS light / dark setting

## 4.3.21

- In Files, dropping a file on a folder's icon did nothing (only its name worked); now it moves into the folder in icon, list and column views

## 4.3.20

- Only one Missing runs at a time: the copy in /Applications replaces one opened from elsewhere (Downloads, a project folder), and updates always install to /Applications
- Files instead of Finder (Settings › Files, off by default): "Show in Finder" in other apps and desktop folders open in Files

## 4.3.19

- Chrome's window still didn't show in ⌘Tab: windows that were wrongly filtered out earlier are now listed when they're on screen

## 4.3.18

- Chrome windows sometimes didn't show in ⌘Tab (when Chrome was too busy to answer macOS); browser windows on screen are now always listed

## 4.3.17

- New tabs in Files' Missing theme: all in one dark container, the selected tab raised

## 4.3.16

- In Files, the file under the pointer gets a light gray highlight (list, icon and column views)
- Sidebar headings in Files open and close instantly when clicked
- Reorder the Files sidebar sections: drag a heading, or right-click › Move Up / Move Down
- Your Files headings and folders in the ⌘Tab panel's sidebar; pick which ones to show in Settings
- Settings › Files › Sidebar layout: edit headings, their order and their folders from there too
- Eject external disks with the ⏏ button in the sidebar; it now shows on every external disk
- Optional: clicking Finder in the Dock opens Files (Settings › Files; ⌥-click opens the real Finder)

## 4.3.15

- In Files' icon view, pressing ⌘ or ⌥ while dragging a file dropped it; fixed
- Dropping in Files works like Finder: ⌘ always moves (it no longer copies), ⌥ always copies

## 4.3.14

- Pressing ⌘ or ⌥ while dragging a file from Files dropped it; Missing's shortcuts no longer hold up the drag

## 4.3.13

- Pressing ⌘Tab while dragging a file from Files cancelled the drag; now the panel opens and you can drop the file on an app's card

## 4.3.12

- Sidebar folders hide their subfolders by default; right-click › Subfolders to show to tick the ones you want
- Clicking the menu bar icon no longer brings the Files window to the front

## 4.3.11

- Downloads lists newest first, grouped under Today, Yesterday, days and months
- Every folder remembers its own sort order and grouping; new sort menu in the toolbar (Date Added included)
- Sidebar folders expand with an arrow to show their subfolders; sections can be collapsed
- Add your own headings to the sidebar and put any folders under them
- Image thumbnails on tab switcher cards

## 4.3.10

- The ⌘" tab switcher always opens in the exact center of the Files window; on a narrow window the cards wrap
- Tab switcher settings (Settings › Files): on / off, grid or list view, folder contents on cards
- A slim favorites column on the right of the tab switcher: click one to open it in a new tab in that window

## 4.3.9

- Files' ⌘" tab switcher didn't work on Turkish Q keyboards (the " key was misdetected); the key is now detected from the keyboard layout

## 4.3.8

- Switch tabs in Files with ⌘" (⌘` on US keyboards): cards like the ⌘Tab panel, ⇧ goes back, release ⌘ to switch
- Files is now a feature of its own in Settings: its own card in Features and its own page in the sidebar

## 4.3.7

- Copy / cross-disk move progress in Files: a card at the bottom right and the status bar show how much is done, how much is left and the time remaining; cancel from the card
- New folder now opens a Missing-style sheet to pick the name and a color
- Color dots in the right-click menu like Finder: they set a color tag, and colored folders are tinted that color

## 4.3.6

- In Files' icon view the left / right arrows continue onto the next / previous row (⇧ extends the selection)

## 4.3.5

- Icon size slider at the bottom right of Files' icon view (like Finder); pinch on the trackpad to zoom too
- In the Missing theme a selected icon gets a light red box around it instead of a red name
- Files Settings now uses Missing's dark glass design
- The menu bar panel now closes when you click a Missing window such as Files, or switch Spaces

## 4.3.4

- Column view in Files like Finder's (⌘3): a selected folder opens in a new column to the right, arrow keys move between columns
- Files Settings (⌘, while Files is in front): view for new windows, theme, hidden files and what the sidebar shows
- Right-click a sidebar item › Hide from Sidebar; tags can be hidden one by one or all at once. Missing Settings is now ⌥⌘,

## 4.3.3

- Locations in the Files sidebar like Finder's: cloud folders such as Google Drive, OneDrive and Dropbox, your home folder, AirDrop, Network and Trash
- Tags: Finder's tags appear with their colors; click one to list every file carrying that tag

## 4.3.2

- In Files, clicking the path bar turns it into a typeable address like in Windows (⌘L); Enter goes there, and a file path opens its folder with the file selected
- Right-click the path bar: Copy Path, Edit Path, Open in New Tab

## 4.3.1

- Opening ⌘Space search while Finder was in front also brought the Files window forward; now only the search opens
- New Dock icon for Files: a blue gradient like Finder's, with the Missing leaf in the middle

## 4.3.0

- New: Files. Missing's own file window that doesn't depend on Finder; it replaces the old Finder tabs strip
- Tabs (drag to reorder, middle-click to close, drop files on a tab to move them there), list and icon views with previews, Quick Look, rename, trash, copy and paste; all undoable with ⌘Z
- Four themes: Missing, Finder, Windows and Glass; Finder and Windows follow the system's light/dark mode
- The search box looks in this folder first, then in every subfolder through the ⌘Space search index
- A preview pane on the right you can show or hide (⇧⌘P), like in Windows Explorer
- Sidebar favorites stay in sync with Finder's sidebar both ways
- While the window is open, Missing shows in the Dock with a folder icon; Add to Dock in Settings pins it, and a click on the icon opens the window
- ⌘Space search and the Finder search box skipped files in subfolders on the first search in a folder that wasn't indexed yet; fixed

## 4.2.2

- In the window switcher, hovering a card no longer changes the selection; click it to switch to that window

## 4.2.1

- Quick equalizer in the menu panel: one-tap Flat, Bass, Treble, Voice and Night presets, a preamp slider and an on/off button

## 4.2.0

- New: Keep awake. Stops the display from turning off and the Mac from sleeping; indefinitely or for 15 minutes to 5 hours
- One choice in the menu panel: a duration, or for as long as an app you pick stays open; ⌘⇧< works too. While on, a cup shows in the menu bar and the time left under the notch
- Automatic rules: only while charging, turn off on low battery, start when Missing opens
- Turns itself off when the lid closes or the Mac sleeps, so it never stays on in a bag
- Optional: keep working with the lid closed. The Mac sleeps when unplugged, when the external display is disconnected, when the time limit is reached or when the battery gets low

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
