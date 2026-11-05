# WinTab

macOS için Windows tarzı **Alt+Tab** (varsayılan **Cmd+Tab**) pencere değiştirici, yanında Lightshot tarzı bir **ekran görüntüsü aracı**. İki Swift dosyası, bağımlılık yok, ~300 KB, Dock'ta görünmez, arka planda hiçbir şey çalıştırmaz.

AltTab ve DockDoor gibi araçlar ağır geldiği için yazıldı. Amaç tek: Windows'taki gibi tüm pencereleri (gizli, simge durumunda ve başka masaüstündekiler dahil) küçük resimleriyle görüp aralarında geçmek. Premium yok, güncelleme servisi yok, telemetri yok.

## Özellikler

- **Cmd+Tab / Alt+Tab / Ctrl+Tab** seçilebilir. Cmd+Tab seçilince macOS'un kendi uygulama değiştiricisi devreye girmez.
- Tuşu basılı tutup **Tab** ile ileri, **Shift+Tab** ile geri, ok tuşları ve fare ile seçim. Tuşu bırakınca geçer, **Esc** iptal.
- **Pencere bazlı** liste (uygulama bazlı değil), son kullanılan önce. Kısa Cmd+Tab bir önceki pencereye döner.
- **Gizli (Cmd+H)**, **simge durumundaki** ve **başka masaüstündeki** pencereler de listede, etiketleriyle. Seçince açar, büyütür, masaüstünü değiştirir.
- Küçük resimler yalnızca panel açıkken çekilir (ScreenCaptureKit). Ekran Kaydı izni yoksa uygulama simgesi gösterilir.
- Tam ekran uygulamaların üstünde de açılır, fare hangi ekrandaysa orada.
- Ayarlar penceresi: kısayol, izin durumu ve tek tıkla ayar sayfası, girişte başlat, **uyku engelle** (Amphetamine'in "Indefinitely" modu gibi: ekran uyumaz, kapak kapanınca uyur).
- **Ekran görüntüsü** (varsayılan **⌘Ğ**, Türkçe olmayan klavyede ⌘[, ayarlardan değiştirilir, istenirse kapatılır): ekran dondurulur, sürükleyerek alan seçilir, kırmızı **çerçeve / ok / kalem** ile işaretlenir. **⌘C** panoya kopyalar (sonra istediğin yere ⌘V), **⌘S** kaydet penceresi açar, **⌘Z** geri alır, **Esc** iptal. Çıktı ekranın gerçek piksel çözünürlüğünde PNG.

## Kurulum

Apple Silicon ve macOS 14+ gerekir. Xcode Command Line Tools yeterli.

```bash
git clone https://github.com/trndogan/WinTab.git
cd WinTab
./make-cert.sh          # bir kez: yerel imza sertifikası (izinlerin korunması için)
./build.sh install      # derle, /Applications'a kur, başlat
```

İlk açılışta ayarlar penceresi gelir ve iki izni ister:

1. **Erişilebilirlik** – kısayolu yakalamak ve pencereleri öne getirmek için zorunlu. Sayfada listede WinTab yoksa **+** ile `/Applications/WinTab.app`'ı ekle ve anahtarı aç. İzin verilir verilmez çalışır, yeniden başlatmak gerekmez.
2. **Ekran Kaydı** – küçük resimler için. Verilince uygulama kendini yeniden başlatır.

### Neden make-cert.sh?

Geliştirici hesabı olmadan derlenen uygulamalar "ad-hoc" imzalanır ve bu imza her derlemede değişir. macOS, Erişilebilirlik ve Ekran Kaydı izinlerini imzaya bağladığı için her derlemeden sonra izinler düşer. `make-cert.sh`, yalnızca bu Mac'te geçerli, kendinden imzalı bir kod imzalama sertifikası üretip giriş anahtar zincirine ekler. `build.sh` bu sertifikayı bulursa onunla imzalar, izinler korunur. Sertifika yoksa ad-hoc'a düşer ve bunu söyler.

## Kullanım

| Tuş | İşlev |
|---|---|
| Cmd+Tab (basılı tut) | Paneli aç, bir sonrakine geç |
| Cmd+Shift+Tab | Bir öncekine |
| ← → ↑ ↓ | Izgarada dolaş |
| Fare | Üstüne gel seç, tıkla geç |
| Cmd bırak / Enter | Seçili pencereye geç |
| Esc | İptal |

Ekran görüntüsü aracında: **1 / 2 / 3** çerçeve, ok, kalem; seçim içinde sürükle işaretler, dışında sürükle yeni alan seçer; **Enter** veya **⌘C** kopyalar, **⌘S** kaydeder, **⌘Z** geri alır, **Esc** iptal.

Menü çubuğundaki simgeden **Ayarlar…**, **Ekran Görüntüsü Al**, **Uyku Engelle** ve **Çıkış**.

## Nasıl çalışıyor

- Pencere listesi `CGWindowListCopyWindowInfo` ile alınır, yalnızca normal uygulamaların 100×50'den büyük, katman 0 pencereleri tutulur. Ekran dışındakiler için Accessibility ile simge durumu ve başlık okunur, başlıksız yardımcı pencereler elenir.
- Kısayol `CGEvent` tap ile yakalanır (Erişilebilirlik izni). Panel açıkken tuşlar yutulur, modifier bırakılınca seçili pencereye geçilir.
- Pencereyi öne getirmek için `AXRaise` + SkyLight `_SLPSSetFrontProcessWithOptions` (AltTab/yabai'nin kullandığı yöntem). Başka masaüstündeki pencereler için masaüstü değiştikten sonra AX ile tekrar öne alınır.
- Küçük resimler `SCScreenshotManager` ile pencere başına, panel açılınca eşzamansız çekilir; panel kapanınca bekleyen sonuçlar atılır.
- Son kullanım sırası `NSWorkspace` aktivasyon bildirimi + aktif uygulamaya `AXObserver` ile takip edilir, zamanlayıcı yok.

## Dosyalar

- `main.swift` – pencere değiştirici, ayarlar, menü
- `Screenshot.swift` – ekran görüntüsü aracı
- `build.sh` – derleme ve kurulum
- `make-cert.sh` – yerel imza sertifikası
- `Info.plist`, `AppIcon.icns` – paket bilgileri ve simge (`assets/make-icon.swift` ile üretildi)

## Lisans

MIT

---

### English

Windows-style Alt+Tab (default Cmd+Tab) window switcher for macOS in two Swift files, plus a Lightshot-style screenshot tool (freeze screen, drag to select, red rectangle/arrow/pen, ⌘C copies, ⌘S saves). Lists every window including hidden, minimized and other-Space ones with live thumbnails, switches on key release, no dependencies, no background work, no premium. Build with `./make-cert.sh` (once) and `./build.sh install`, then grant Accessibility and Screen Recording from the settings window it opens. Apple Silicon, macOS 14+.
