import AppKit

// MARK: - Remote updates (GitHub Releases)
//
// AllTab looks at https://github.com/trndogan/AllTab/releases/latest, and when there is a newer
// version it offers to download the zip, checks the new app, swaps it in and restarts.
// Nothing runs in the background: one check at launch (at most once a day) or when you ask.
//
// Safety: the downloaded app is only installed when macOS says its signature is intact and it
// is signed by the same Apple Developer team as official AllTab builds, has the same bundle
// identifier, and a higher version number than the running one.
// Because the signature stays the same, Accessibility / Screen Recording permissions survive updates.

enum Updater {
    static let repo = "trndogan/AllTab"
    static let teamID = "F5J976CTFT"
    static let bundleID = "com.turandogan.alltab"

    static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
    }
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    private static var busy = false

    /// Called once at launch: silent unless a newer version exists.
    static func checkIfDue() {
        guard autoCheck else { return }
        let d = UserDefaults.standard
        if let last = d.object(forKey: "lastUpdateCheck") as? Date, Date().timeIntervalSince(last) < 24 * 3600 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { check(interactive: false) }
    }

    /// 1.10 > 1.9 > 1.9.1-less comparisons by numeric parts ("v" prefix allowed).
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    struct Release { let version: String; let notes: String; let zipURL: URL?; let pageURL: URL? }

    static func check(interactive: Bool) {
        guard !busy else { return }
        busy = true
        UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
        var api = "https://api.github.com/repos/\(repo)/releases/latest"
        if debugLog, let o = UserDefaults.standard.string(forKey: "debugUpdateAPI") { api = o }   // test hook, only with --debug
        var req = URLRequest(url: URL(string: api)!, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AllTab/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                busy = false
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard err == nil, let data else {
                    if interactive { info(L.t("Could not check for updates", "Güncelleme denetlenemedi"), err?.localizedDescription ?? L.t("No connection.", "Bağlantı yok.")) }
                    return
                }
                if status == 404 {
                    if interactive { info(L.t("You're up to date", "Güncelsin"), L.t("AllTab \(currentVersion) is the latest version.", "AllTab \(currentVersion) en son sürüm.")) }
                    return
                }
                guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    if interactive { info(L.t("Could not check for updates", "Güncelleme denetlenemedi"), "GitHub: HTTP \(status)") }
                    return
                }
                let assets = json["assets"] as? [[String: Any]] ?? []
                let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }?["browser_download_url"] as? String
                let rel = Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                                  notes: (json["body"] as? String) ?? "",
                                  zipURL: zip.flatMap(URL.init(string:)),
                                  pageURL: (json["html_url"] as? String).flatMap(URL.init(string:)))
                guard isNewer(rel.version, than: currentVersion) else {
                    if interactive { info(L.t("You're up to date", "Güncelsin"), L.t("AllTab \(currentVersion) is the latest version.", "AllTab \(currentVersion) en son sürüm.")) }
                    return
                }
                if !interactive, UserDefaults.standard.string(forKey: "skippedVersion") == rel.version { return }
                offer(rel, interactive: interactive)
            }
        }.resume()
    }

    private static func info(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private static func offer(_ rel: Release, interactive: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L.t("AllTab \(rel.version) is available", "AllTab \(rel.version) çıktı")
        var text = L.t("You have \(currentVersion).", "Sende \(currentVersion) var.")
        let notes = rel.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { text += "\n\n" + String(notes.prefix(600)) }
        a.informativeText = text
        a.addButton(withTitle: rel.zipURL != nil ? L.t("Update and Restart", "Güncelle ve Yeniden Başlat") : L.t("Open Release Page", "Sürüm Sayfasını Aç"))
        a.addButton(withTitle: L.t("Later", "Sonra"))
        if !interactive { a.addButton(withTitle: L.t("Skip This Version", "Bu Sürümü Atla")) }
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if rel.zipURL != nil { install(rel) } else if let p = rel.pageURL { NSWorkspace.shared.open(p) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(rel.version, forKey: "skippedVersion")
        default: break
        }
    }

    // MARK: Download, verify, swap

    private static func fail(_ text: String, page: URL?) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L.t("Update failed", "Güncelleme yapılamadı")
        a.informativeText = text
        a.addButton(withTitle: "OK")
        if page != nil { a.addButton(withTitle: L.t("Open Release Page", "Sürüm Sayfasını Aç")) }
        if a.runModal() == .alertSecondButtonReturn, let page { NSWorkspace.shared.open(page) }
    }

    private static func install(_ rel: Release) {
        guard let zipURL = rel.zipURL else { return }
        let dest = Bundle.main.bundlePath
        let parent = (dest as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            fail(L.t("AllTab cannot replace itself in \(parent) (no write permission). Download the new version by hand.",
                     "AllTab, \(parent) klasöründe kendini değiştiremiyor (yazma izni yok). Yeni sürümü elle indir."), page: rel.pageURL)
            return
        }
        busy = true
        let task = URLSession.shared.downloadTask(with: zipURL) { tmp, resp, err in
            // The temp file is deleted when this closure returns, so move it first.
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("AllTab-update-\(UUID().uuidString)")
            var zipPath: URL?
            if let tmp, (resp as? HTTPURLResponse)?.statusCode == 200, err == nil,
               (try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)) != nil {
                let z = work.appendingPathComponent("AllTab.zip")
                if (try? FileManager.default.moveItem(at: tmp, to: z)) != nil { zipPath = z }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<URL, UpdateError> = zipPath.map { prepare(zip: $0, work: work) } ?? .failure(.download(err?.localizedDescription))
                DispatchQueue.main.async {
                    busy = false
                    switch result {
                    case .success(let newApp): swapAndRestart(newApp: newApp, work: work, dest: dest)
                    case .failure(let e):
                        try? FileManager.default.removeItem(at: work)
                        fail(e.message, page: rel.pageURL)
                    }
                }
            }
        }
        task.resume()
    }

    enum UpdateError: Error {
        case download(String?), unzip, noApp, badSignature, wrongTeam(String), wrongID(String), notNewer(String)
        var message: String {
            switch self {
            case .download(let s): return L.t("Download failed. ", "İndirme başarısız. ") + (s ?? "")
            case .unzip: return L.t("The downloaded file could not be unpacked.", "İndirilen dosya açılamadı.")
            case .noApp: return L.t("The download does not contain AllTab.app.", "İndirilen dosyada AllTab.app yok.")
            case .badSignature: return L.t("The new app's signature is not valid, so it was not installed.", "Yeni uygulamanın imzası geçerli değil, kurulmadı.")
            case .wrongTeam(let t): return L.t("The new app is not signed by the AllTab developer (\(t)), so it was not installed.", "Yeni uygulama AllTab geliştiricisi tarafından imzalanmamış (\(t)), kurulmadı.")
            case .wrongID(let i): return L.t("Unexpected app identifier \(i), so it was not installed.", "Beklenmeyen uygulama kimliği \(i), kurulmadı.")
            case .notNewer(let v): return L.t("The download is version \(v), which is not newer than the running one.", "İndirilen sürüm \(v), çalışandan yeni değil.")
            }
        }
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Unzip, then verify. Returns the path of the verified new app.
    private static func prepare(zip: URL, work: URL) -> Result<URL, UpdateError> {
        let out = work.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]).status == 0 else { return .failure(.unzip) }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: out.path))?.filter { $0.hasSuffix(".app") } ?? []
        guard let name = apps.first(where: { $0 == "AllTab.app" }) ?? apps.first else { return .failure(.noApp) }
        let app = out.appendingPathComponent(name)

        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else { return .failure(.badSignature) }
        let detail = run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path]).output
        let team = detail.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) } ?? "none"
        guard team == teamID else { return .failure(.wrongTeam(team)) }

        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let id = plist?["CFBundleIdentifier"] as? String ?? ""
        guard id == bundleID else { return .failure(.wrongID(id)) }
        let version = plist?["CFBundleShortVersionString"] as? String ?? "0"
        guard isNewer(version, than: currentVersion) else { return .failure(.notNewer(version)) }
        return .success(app)
    }

    /// A detached shell waits for us to quit, swaps the bundle (keeping the old one until the new one is in place), reopens.
    private static func swapAndRestart(newApp: URL, work: URL, dest: String) {
        let script = """
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        if /bin/mv "$DEST" "$DEST.old" && /usr/bin/ditto "$NEW" "$DEST"; then
          /bin/rm -rf "$DEST.old"
        else
          /bin/rm -rf "$DEST"; /bin/mv "$DEST.old" "$DEST"
        fi
        /bin/rm -rf "$WORK"
        /usr/bin/open "$DEST"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["PID": "\(getpid())", "DEST": dest, "NEW": newApp.path, "WORK": work.path]
        guard (try? p.run()) != nil else {
            fail(L.t("The installer could not be started.", "Kurulum başlatılamadı."), page: nil)
            return
        }
        NSApp.terminate(nil)
    }
}
