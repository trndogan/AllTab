# AllTab

Windows-style **Alt+Tab** (default **Cmd+Tab**) window switcher for macOS that shows **all** windows, including hidden, minimized and other-Space ones, with live thumbnails. Comes with a Lightshot-style screenshot tool and a keep-awake toggle. Two Swift files, no dependencies, ~300 KB, no Dock icon, nothing running in the background.

Built because AltTab and DockDoor felt heavy and kept pushing premium features. No premium, no updater, no telemetry.

## Features

- **Cmd+Tab / Alt+Tab / Ctrl+Tab** selectable. With Cmd+Tab the native macOS app switcher never appears.
- Hold the modifier, **Tab** forward, **Shift+Tab** back, arrow keys and mouse work too. Release to switch, **Esc** to cancel.
- **Per-window** list (not per-app), most recently used first. A quick Cmd+Tab returns to the previous window.
- **Hidden (Cmd+H)**, **minimized**, **other-desktop** and **full screen** windows are listed with a badge. Selecting one unhides, restores or switches Space as needed. Windows an app has put away on no desktop at all (Chrome keeps such windows) are left out, since nothing can bring them up.
- **Two layouts** (Settings ▸ Layout): side by side with thumbnails (default), or a plain vertical list with one row per window (icon, title, ×). The list grows a second column only when the windows do not fit on the screen.
- **Close without switching**: while the list is open, **W** or the **×** button (top right of a cell) closes that window. The list stays open, so you can clean up several windows in one go. Apps still ask before discarding unsaved changes.
- **Dock preview**: hover over a running app's icon in the Dock and its windows (hidden, minimized and other-desktop ones too) appear above the icon with thumbnails. Click one to open it, × closes it. Off by default, turn it on in Settings.
- **Works with Secure Keyboard Entry**: when another app locks the keyboard (a password field in Chrome, a passcode screen, Terminal's Secure Keyboard Entry), macOS hides keystrokes from event taps. AllTab registers its shortcuts a second way that macOS still delivers then, so Cmd+Tab and the screenshot shortcut keep working.
- Thumbnails are captured only while the panel is open (ScreenCaptureKit). Without Screen Recording permission, app icons are shown instead.
- Opens on top of full-screen apps, on the screen where the mouse is.
- **Screenshot tool** (default **⌘Ğ** on Turkish keyboards, ⌘[ elsewhere; change it in Settings or turn it off): freeze the screen, drag to select, mark with a red **rectangle / arrow / pen**. **⌘C** copies (then ⌘V anywhere), **⌘S** saves, **⌘Z** undoes, **Esc** cancels. Move the selected area (marks move with it) with the **✥ Move** tool (**4**), by holding **Space** while dragging, or with the arrow keys (Shift = 10 px). Output is a PNG at native pixel resolution.
- **Keep awake**: like Amphetamine's "Indefinitely" mode, the display never sleeps, closing the lid still sleeps.
- **Finder swipe navigation**: swipe right with two fingers in a Finder window to go Back, left to go Forward, like Chrome and Safari. It presses Finder's own Go ▸ Back / Forward, so it works in every language and keyboard layout. Can be turned off in Settings.
- **Updates**: one check at launch (at most once a day, no background timer) or **Check for Updates…** in the menu. A newer GitHub release is downloaded, verified (valid signature, same developer team, same bundle id, higher version) and swapped in, then AllTab restarts. Permissions survive because the signature stays the same.
- Settings window (two columns, fits a laptop screen) with permission status and one-click links to the right System Settings pane. The Settings window itself shows up in the switcher while it is open. Launch at login via `SMAppService`.
- UI in English, or Turkish when the system language is Turkish.

## Install

Apple Silicon, macOS 14 or newer. Xcode Command Line Tools are enough.

```bash
git clone https://github.com/trndogan/AllTab.git
cd AllTab
./make-cert.sh          # only without an Apple Developer certificate, see Signing below
./build.sh install      # build, install to /Applications, launch
```

On first launch the Settings window opens and asks for two permissions:

1. **Accessibility** – required to capture the shortcut and bring windows to front. If AllTab is missing from the list, add `/Applications/AllTab.app` with **+** and turn it on. It starts working immediately, no restart needed.
2. **Screen Recording** – for thumbnails and the screenshot tool. macOS only reads this permission when an app starts, so AllTab watches for the grant (a fresh copy of itself checks every 2 seconds, only while the permission is missing) and restarts itself within a couple of seconds. You can ignore macOS's own "Quit & Reopen" dialog.

### Signing

`build.sh` picks the first available identity: `SIGN_IDENTITY` env var, then **Developer ID Application**, then **Apple Development**, then the local certificate from `make-cert.sh`, otherwise ad-hoc.

If you have an Apple Developer account, install your certificate once (Xcode → Settings → Accounts → Manage Certificates) and skip `make-cert.sh`. Without one, `make-cert.sh` creates a self-signed code-signing certificate in your login keychain; macOS asks for your login password once for the trust setting and once when codesign first uses the key (choose "Always Allow"). Either way the signature stays the same across rebuilds, which matters because macOS ties Accessibility and Screen Recording permissions to the signature: with an ad-hoc signature every rebuild would drop them.

## Usage

| Keys | Action |
|---|---|
| Cmd+Tab (hold) | Open the switcher, move to the next window |
| Cmd+Shift+Tab | Previous window |
| ← → ↑ ↓ | Move around the grid |
| Mouse | Click a window to switch, its × to close it |
| W | Close the selected window |
| Release Cmd / Enter | Switch to the selected window |
| Esc | Cancel |

Screenshot tool: **1 / 2 / 3** choose rectangle, arrow, pen; drag inside the selection to mark (or use **4** / hold **Space** to move it), drag outside to select a new area; **Enter** or **⌘C** copies, **⌘S** saves, **⌘Z** undoes, **Esc** cancels.

Menu bar icon: **Settings…**, **Take Screenshot**, **Keep Awake**, **Quit**.

## How it works

- Windows come from `CGWindowListCopyWindowInfo`, keeping only layer-0 windows of regular apps larger than 100×50. Off-screen windows get their minimized state and title via Accessibility; untitled helper windows are dropped.
- The shortcut is captured with a `CGEvent` tap (Accessibility permission). While the panel is open, keys are swallowed; releasing the modifier switches. The same shortcuts are also registered with `RegisterEventHotKey`, which still fires under Secure Keyboard Entry; with Cmd+Tab, macOS's own Cmd+Tab is turned off while AllTab runs (`CGSSetSymbolicHotKeyEnabled`) and turned back on when it quits.
- The Dock preview listens to the Dock's own Accessibility notification for the icon under the mouse (`kAXSelectedChildrenChanged`), so nothing polls.
- Windows are brought to front with `AXRaise` plus SkyLight `_SLPSSetFrontProcessWithOptions`, the same approach AltTab and yabai use. AllTab never activates itself, otherwise macOS would hand focus back to the previous app. Accessibility only lists windows of the current Space, so each window's element is remembered once seen (and found by a time-boxed remote-token scan otherwise); raising the window itself is what leaves the current Space when the app already has a window there, as with a full screen YouTube video in Chrome. If the window is still not on screen after the Space switch, the raise is repeated once, guarded by a generation counter so rapid successive switches never undo each other.
- Thumbnails are taken per window with `SCScreenshotManager`, asynchronously, only while the panel is open; results arriving after it closes are discarded.
- MRU order is tracked through `NSWorkspace` activation notifications and an `AXObserver` on the active app. No timers.
- The swipe uses a passive `NSEvent` global scroll monitor: trackpad gestures only (mouse wheels and inertia are ignored), and the gesture must start over a Finder window while Finder is frontmost.
- Debugging: `open -a AllTab --args --debug` logs every switch to `~/Library/Logs/AllTab.log`.

## Files

- `main.swift` – switcher, settings, menu
- `Screenshot.swift` – screenshot tool
- `Keys.swift` – backup shortcuts that work under Secure Keyboard Entry
- `DockPreview.swift` – window preview on Dock icons
- `Gestures.swift` – two-finger swipe navigation in Finder
- `Updater.swift` – update check, download, verification, swap
- `build.sh` – build and install
- `release.sh` – zip the build and publish a GitHub release (what the updater downloads)
- `make-cert.sh` – local signing certificate
- `Info.plist`, `AppIcon.icns` – bundle info and icon (generated by `assets/make-icon.swift`)

## License

MIT

---

### Türkçe

macOS için Windows tarzı Alt+Tab (varsayılan Cmd+Tab) pencere değiştirici. Gizli, simge durumundaki, başka masaüstündeki ve tam ekran pencereler dahil **tüm** pencereleri küçük resimleriyle listeler, tuşu bırakınca geçer. Ayarlar'dan yan yana küçük resimli ya da sade dikey liste görünümü seçilebilir. Liste açıkken W ya da × düğmesi pencereyi kapatır. Ayarlar'dan açılırsa, Dock'ta bir uygulamanın simgesinin üzerine gelince açık pencereleri küçük resimleriyle listelenir. Başka bir uygulama klavyeyi kilitlese de (Chrome'da şifre alanı gibi) kısayollar çalışmaya devam eder. Yanında Lightshot tarzı ekran görüntüsü aracı (⌘Ğ, alan seç, kırmızı çerçeve/ok/kalem, ⌘C kopyala, ⌘S kaydet) ve uyku engelleme var. Kurulum: `./make-cert.sh` (bir kez) ve `./build.sh install`, ardından açılan ayarlar penceresinden Erişilebilirlik ve Ekran Kaydı izinlerini ver. Sistem dili Türkçeyse arayüz Türkçedir.
