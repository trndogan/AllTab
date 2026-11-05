# AllTab

Windows-style **Alt+Tab** (default **Cmd+Tab**) window switcher for macOS that shows **all** windows, including hidden, minimized and other-Space ones, with live thumbnails. Comes with a Lightshot-style screenshot tool and a keep-awake toggle. Two Swift files, no dependencies, ~300 KB, no Dock icon, nothing running in the background.

Built because AltTab and DockDoor felt heavy and kept pushing premium features. No premium, no updater, no telemetry.

## Features

- **Cmd+Tab / Alt+Tab / Ctrl+Tab** selectable. With Cmd+Tab the native macOS app switcher never appears.
- Hold the modifier, **Tab** forward, **Shift+Tab** back, arrow keys and mouse work too. Release to switch, **Esc** to cancel.
- **Per-window** list (not per-app), most recently used first. A quick Cmd+Tab returns to the previous window.
- **Hidden (Cmd+H)**, **minimized** and **other-desktop** windows are listed with a badge. Selecting one unhides, restores or switches Space as needed.
- Thumbnails are captured only while the panel is open (ScreenCaptureKit). Without Screen Recording permission, app icons are shown instead.
- Opens on top of full-screen apps, on the screen where the mouse is.
- **Screenshot tool** (default **⌘Ğ** on Turkish keyboards, ⌘[ elsewhere; change it in Settings or turn it off): freeze the screen, drag to select, mark with a red **rectangle / arrow / pen**. **⌘C** copies (then ⌘V anywhere), **⌘S** saves, **⌘Z** undoes, **Esc** cancels. Output is a PNG at native pixel resolution.
- **Keep awake**: like Amphetamine's "Indefinitely" mode, the display never sleeps, closing the lid still sleeps.
- Settings window with permission status and one-click links to the right System Settings pane. Launch at login via `SMAppService`.
- UI in English, or Turkish when the system language is Turkish.

## Install

Apple Silicon, macOS 14 or newer. Xcode Command Line Tools are enough.

```bash
git clone https://github.com/trndogan/AllTab.git
cd AllTab
./make-cert.sh          # once: local signing certificate (keeps permissions across rebuilds)
./build.sh install      # build, install to /Applications, launch
```

On first launch the Settings window opens and asks for two permissions:

1. **Accessibility** – required to capture the shortcut and bring windows to front. If AllTab is missing from the list, add `/Applications/AllTab.app` with **+** and turn it on. It starts working immediately, no restart needed.
2. **Screen Recording** – for thumbnails and the screenshot tool. AllTab restarts itself after you grant it.

### Why make-cert.sh?

Apps built without a developer account are "ad-hoc" signed and the signature changes on every build. macOS ties Accessibility and Screen Recording permissions to the signature, so every rebuild would drop them. `make-cert.sh` creates a self-signed code-signing certificate ("AllTab Local Signing") in your login keychain, valid only on this Mac. `build.sh` signs with it when present, so permissions survive rebuilds. Without it, the build falls back to ad-hoc and says so.

## Usage

| Keys | Action |
|---|---|
| Cmd+Tab (hold) | Open the switcher, move to the next window |
| Cmd+Shift+Tab | Previous window |
| ← → ↑ ↓ | Move around the grid |
| Mouse | Hover to select, click to switch |
| Release Cmd / Enter | Switch to the selected window |
| Esc | Cancel |

Screenshot tool: **1 / 2 / 3** choose rectangle, arrow, pen; drag inside the selection to mark, drag outside to select a new area; **Enter** or **⌘C** copies, **⌘S** saves, **⌘Z** undoes, **Esc** cancels.

Menu bar icon: **Settings…**, **Take Screenshot**, **Keep Awake**, **Quit**.

## How it works

- Windows come from `CGWindowListCopyWindowInfo`, keeping only layer-0 windows of regular apps larger than 100×50. Off-screen windows get their minimized state and title via Accessibility; untitled helper windows are dropped.
- The shortcut is captured with a `CGEvent` tap (Accessibility permission). While the panel is open, keys are swallowed; releasing the modifier switches.
- Windows are brought to front with `AXRaise` plus SkyLight `_SLPSSetFrontProcessWithOptions`, the same approach AltTab and yabai use. AllTab never activates itself, otherwise macOS would hand focus back to the previous app. For windows on another Space the raise is repeated once after the Space switch, guarded by a generation counter so rapid successive switches never undo each other.
- Thumbnails are taken per window with `SCScreenshotManager`, asynchronously, only while the panel is open; results arriving after it closes are discarded.
- MRU order is tracked through `NSWorkspace` activation notifications and an `AXObserver` on the active app. No timers.
- Debugging: `open -a AllTab --args --debug` logs every switch to `~/Library/Logs/AllTab.log`.

## Files

- `main.swift` – switcher, settings, menu
- `Screenshot.swift` – screenshot tool
- `build.sh` – build and install
- `make-cert.sh` – local signing certificate
- `Info.plist`, `AppIcon.icns` – bundle info and icon (generated by `assets/make-icon.swift`)

## License

MIT

---

### Türkçe

macOS için Windows tarzı Alt+Tab (varsayılan Cmd+Tab) pencere değiştirici. Gizli, simge durumundaki ve başka masaüstündeki pencereler dahil **tüm** pencereleri küçük resimleriyle listeler, tuşu bırakınca geçer. Yanında Lightshot tarzı ekran görüntüsü aracı (⌘Ğ, alan seç, kırmızı çerçeve/ok/kalem, ⌘C kopyala, ⌘S kaydet) ve uyku engelleme var. Kurulum: `./make-cert.sh` (bir kez) ve `./build.sh install`, ardından açılan ayarlar penceresinden Erişilebilirlik ve Ekran Kaydı izinlerini ver. Sistem dili Türkçeyse arayüz Türkçedir.
