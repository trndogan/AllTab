import AppKit
import ApplicationServices

// MARK: - Two-finger swipe navigation in Finder
//
// Finder has no swipe-to-go-back. Chrome and Safari do: swipe right with two fingers to go back,
// left to go forward. This brings the same gesture to Finder windows by pressing Finder's own
// "Back" / "Forward" menu items (found by position, so it works in every language and keyboard layout). It is a passive scroll-wheel monitor: nothing runs unless you scroll.

enum SwipeNav {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "swipeNav") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "swipeNav"); apply() }
    }

    private static let finderBundleID = "com.apple.finder"
    private static var monitor: Any?
    private static var dx: CGFloat = 0
    private static var dy: CGFloat = 0
    private static var tracking = false   // this gesture started over a Finder window
    private static var fired = false

    /// Horizontal distance (points) a swipe has to travel, and how much more horizontal than vertical it must be.
    private static let threshold: CGFloat = 110
    private static let dominance: CGFloat = 2

    static func apply() {
        if enabled, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { handle($0) }
        } else if !enabled, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private static func handle(_ e: NSEvent) {
        // Trackpad gestures only: mouse wheels and momentum (inertia) events have no `phase`.
        let phase = e.phase
        guard !phase.isEmpty else { return }
        if phase.contains(.began) {
            dx = 0; dy = 0; fired = false
            tracking = frontmostFinderWindowUnderCursor()
            return
        }
        guard tracking else { return }
        if phase.contains(.ended) || phase.contains(.cancelled) { tracking = false; return }
        guard phase.contains(.changed), !fired else { return }

        // Finger direction: with natural scrolling the delta already follows the fingers.
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        dx += e.scrollingDeltaX * sign
        dy += e.scrollingDeltaY
        if abs(dy) > 60, abs(dy) > abs(dx) { tracking = false; return }   // it is a vertical scroll
        guard abs(dx) >= threshold, abs(dx) >= abs(dy) * dominance else { return }
        fired = true
        go(back: dx > 0)   // fingers moved right = back
    }

    /// Is the topmost window under the cursor a Finder window, and is Finder the frontmost app?
    private static func frontmostFinderWindowUnderCursor() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == finderBundleID else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let m = NSEvent.mouseLocation
        let point = CGPoint(x: m.x, y: primaryHeight - m.y)
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in infos {   // front to back
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.contains(point) else { continue }
            return (w[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier
        }
        return false
    }

    static func go(back: Bool) {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == finderBundleID else { return }
        let pid = front.processIdentifier
        DispatchQueue.global(qos: .userInteractive).async {
            let ok = pressMenuItem(pid: pid, back: back)
            dlog("swipe \(back ? "back" : "forward") pressed=\(ok)")
        }
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? (v as AnyObject?) : nil
    }

    /// Presses Finder's Go ▸ Back / Forward. The menu is found by position (the sixth menu bar item, its
    /// first two entries), not by title or shortcut character, because both change with the language and
    /// keyboard layout (on a Turkish keyboard ⌘[ is reported as "Ğ"). Sanity check: both entries must
    /// carry a plain-⌘ shortcut.
    private static func pressMenuItem(pid: pid_t, back: Bool) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = attr(app, kAXMenuBarAttribute as String) else { return false }
        let tops = (attr(bar as! AXUIElement, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
        guard tops.count >= 6,
              let menu = (attr(tops[5], kAXChildrenAttribute as String) as? [AXUIElement])?.first,
              let items = attr(menu, kAXChildrenAttribute as String) as? [AXUIElement], items.count >= 2 else { return false }
        func plainCmd(_ i: AXUIElement) -> Bool {
            ((attr(i, kAXMenuItemCmdCharAttribute as String) as? String) ?? "").isEmpty == false
                && (attr(i, kAXMenuItemCmdModifiersAttribute as String) as? Int ?? -1) == 0
        }
        let item = items[back ? 0 : 1]
        guard plainCmd(items[0]), plainCmd(items[1]),
              (attr(item, kAXEnabledAttribute as String) as? Bool) == true else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }
}
