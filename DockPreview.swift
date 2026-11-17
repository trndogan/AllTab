import AppKit
import ApplicationServices

// MARK: - Dock preview
//
// Hover over a running app's icon in the Dock and its open windows (hidden, minimized and other-desktop
// ones too) appear above the icon with thumbnails, the same cells as the switcher: click one to open it,
// its × closes it. Event driven: the Dock reports the icon under the mouse through
// Accessibility (kAXSelectedChildrenChanged on its icon list), nothing polls.

final class DockPreview {
    let preview: Switcher
    private var observer: AXObserver?
    private var list: AXUIElement?
    private var retry: Timer?
    /// App under the mouse in the Dock (nil when the mouse is not on a running app's icon)
    private var hovered: NSRunningApplication?
    private var pendingShow: DispatchWorkItem?
    private var pendingHide: DispatchWorkItem?
    /// While the preview is open: the hovered icon and the whole Dock, for the mouse watch below
    private var anchor: CGRect = .zero
    private var dockArea: CGRect = .zero
    private var watch: Timer?
    private var outsideTicks = 0

    /// Off by default: turned on in Settings.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "dockPreview") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "dockPreview") }
    }

    init(tracker: FocusTracker) {
        preview = Switcher(mode: .dock, tracker: tracker)
        preview.onMouseLeft = { [weak self] in self?.scheduleHide() }
        preview.onVisibility.append { [weak self] open in if !open { self?.stopWatch() } }
        let ws = NSWorkspace.shared.notificationCenter
        // The Dock restarts (killall Dock, display changes): its Accessibility elements are new, attach again.
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.apple.dock" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.apply() }
        }
        // A click on a Dock icon activates the app: the preview has done its job.
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.preview.visible, !self.mouseInPreview else { return }
            self.preview.cancel()
        }
        apply()
    }

    /// Turns the preview on or off (Settings) and attaches to the Dock.
    func apply() {
        detach()
        guard Self.enabled else { preview.cancel(); return }
        if !attach() {
            // No Accessibility yet, or the Dock is not up: try again quietly until it works.
            retry?.invalidate()
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self, Self.enabled else { t.invalidate(); return }
                if self.attach() { t.invalidate() }
            }
        }
    }

    private func detach() {
        retry?.invalidate(); retry = nil
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode) }
        observer = nil; list = nil
    }

    private func attach() -> Bool {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let list = (axValue(app, kAXChildrenAttribute) as? [AXUIElement])?
                .first(where: { (axValue($0, kAXRoleAttribute) as? String) == (kAXListRole as String) }) else { return false }
        var o: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<DockPreview>.fromOpaque(refcon).takeUnretainedValue().hoverChanged()
        }
        guard AXObserverCreate(dock.processIdentifier, cb, &o) == .success, let o,
              AXObserverAddNotification(o, list, kAXSelectedChildrenChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        observer = o
        self.list = list
        dlog("dock: baglandi, \((axValue(list, kAXChildrenAttribute) as? [AXUIElement])?.count ?? 0) simge")
        return true
    }

    private var mouseInPreview: Bool { preview.visible && preview.panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) }

    /// The icon under the mouse changed (or the mouse left the Dock).
    private func hoverChanged() {
        let item = (list.flatMap { axValue($0, kAXSelectedChildrenAttribute) } as? [AXUIElement])?.first
        guard let item, (axValue(item, kAXSubroleAttribute) as? String) == "AXApplicationDockItem",
              let app = Self.runningApp(item), let frame = Self.frame(item) else {
            hovered = nil
            pendingShow?.cancel()
            scheduleHide()
            return
        }
        dlog("dock: uzerinde \(app.localizedName ?? "?")")
        hovered = app
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovered == app, Self.enabled else { return }
            self.preview.showDock(app, anchor: frame)
            guard self.preview.visible else { return }
            self.anchor = frame
            self.dockArea = self.list.flatMap { Self.frame($0) } ?? frame
            self.startWatch()
        }
        pendingShow?.cancel()
        pendingShow = work
        // A short wait before the first preview so sweeping across the Dock does not flash; once one is open,
        // moving to the next icon switches right away.
        DispatchQueue.main.asyncAfter(deadline: .now() + (preview.visible ? 0.05 : 0.3), execute: work)
    }

    /// Hides the preview a moment later unless the mouse is on an app icon again or inside the preview
    /// (on its way from the icon up to the preview).
    private func scheduleHide() {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovered == nil, !self.mouseInPreview else { return }
            self.preview.cancel()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// The Dock does not always report that the mouse left it (a quick flick off the Dock, the Dock hiding
    /// itself), and then the preview stayed open. So while it is open the mouse is also checked a few times
    /// a second: outside the preview, the Dock and the space between the icon and the preview for about
    /// half a second, and it closes. Runs only while the preview is open.
    private func startWatch() {
        outsideTicks = 0
        guard watch == nil else { return }
        watch = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.preview.visible else { self.stopWatch(); return }
            let m = NSEvent.mouseLocation
            let p = self.preview.panel.frame
            let safe = [p.insetBy(dx: -8, dy: -8), self.dockArea.insetBy(dx: -4, dy: -4), self.anchor.union(p)]
            if safe.contains(where: { $0.contains(m) }) { self.outsideTicks = 0; return }
            self.outsideTicks += 1
            guard self.outsideTicks >= 3 else { return }
            dlog("dock: fare disarida, onizleme kapandi")
            self.hovered = nil
            self.pendingShow?.cancel()
            self.preview.cancel()
        }
    }

    private func stopWatch() {
        watch?.invalidate()
        watch = nil
    }

    private static func runningApp(_ item: AXUIElement) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let url = axValue(item, kAXURLAttribute) as? URL {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if let a = apps.first(where: { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == path }) { return a }
        }
        let title = axValue(item, kAXTitleAttribute) as? String
        return title.flatMap { t in apps.first { $0.localizedName == t } }
    }

    /// The icon's frame in Cocoa screen coordinates (Accessibility reports top-left origin coordinates).
    private static func frame(_ item: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = axValue(item, kAXPositionAttribute), let sv = axValue(item, kAXSizeAttribute),
              AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: p.x, y: primaryHeight - p.y - s.height, width: s.width, height: s.height)
    }

    /// Debug: what the Dock reports, without touching anything.
    func describe() -> String {
        guard let list else { return "dock: bagli degil (erisilebilirlik=\(AXIsProcessTrusted()))" }
        let items = (axValue(list, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        let apps = items.filter { (axValue($0, kAXSubroleAttribute) as? String) == "AXApplicationDockItem" }
        let running = apps.compactMap { Self.runningApp($0) }
        let f = apps.first.flatMap { Self.frame($0) }
        return "dock: \(items.count) simge, \(apps.count) uygulama, \(running.count) calisan, ilk simge=\(f.map { "\($0)" } ?? "-")"
    }
}
