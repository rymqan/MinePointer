import AppKit
import Carbon.HIToolbox

/// Synthetic mouse via CGEvent at the HID tap. Verified live: Minecraft 26.3 (SDL3) accepts it in-game and in the inventory.
final class MouseOutput {
    private(set) var leftDown = false
    private(set) var rightDown = false

    private var bounds = CGRect.null
    /// MINEPOINTER_TRACE=1: every posted event goes to logs/output-*.csv (uptime, kind, dx, dy, cursor before, posted location).
    private let trace: FileHandle? = {
        guard ProcessInfo.processInfo.environment["MINEPOINTER_TRACE"] == "1" else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = logsFolder.appendingPathComponent("output-\(f.string(from: Date())).csv")
        FileManager.default.createFile(atPath: url.path, contents: Data("uptime,kind,dx,dy,cursor_x,cursor_y,posted_x,posted_y\n".utf8))
        return try? FileHandle(forWritingTo: url)
    }()

    /// Trace only: physical key events and frontmost-app changes, listen-only, to tell "the key-up never reached the system"
    /// from "the game lost focus" from "the game ignored it" (stuck W/S after a jerk up). The same events are recorded at the
    /// HID tap (key_*) and at the annotated session tap just before routing to the app (skey_*): a key-up seen at the first but
    /// not the second was dropped inside the window server (e.g. local-event suppression after our posted events).
    /// Columns: dx = key code, dy = 1 if autorepeat, cursor = event location, posted_x = source pid.
    private final class KeyTap {
        let prefix: String
        weak var output: MouseOutput?
        var port: CFMachPort?
        init(prefix: String, output: MouseOutput) { self.prefix = prefix; self.output = output }
    }
    private var keyTaps: [KeyTap] = []
    private var appObserver: NSObjectProtocol?

    init() {
        guard trace != nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        for (location, prefix) in [(CGEventTapLocation.cghidEventTap, "key"), (.cgAnnotatedSessionEventTap, "skey")] {
            let tap = KeyTap(prefix: prefix, output: self)
            keyTaps.append(tap)
            tap.port = CGEvent.tapCreate(tap: location, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                                         callback: { _, type, event, refcon in
                let tap = Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
                    tap.output?.record("\(tap.prefix)_tap_reenabled", 0, 0, .zero, .zero)
                } else {
                    tap.output?.record("\(tap.prefix)_\(type == .keyDown ? "down" : "up")", Int(event.getIntegerValueField(.keyboardEventKeycode)),
                                       Int(event.getIntegerValueField(.keyboardEventAutorepeat)), event.location,
                                       CGPoint(x: Double(event.getIntegerValueField(.eventSourceUnixProcessID)), y: 0))
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(tap).toOpaque())
            if let port = tap.port {
                CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            } else { record("\(prefix)_tap_failed", 0, 0, .zero, .zero) }
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                        object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let name = (app?.localizedName ?? "?").replacingOccurrences(of: ",", with: " ")
            self?.record("app_active:\(name)", 0, 0, .zero, .zero)
        }
    }

    /// Trace only: a timing note (dx = milliseconds), for the choppy-camera stalls.
    func note(_ kind: String, ms: Double) { record(kind, Int(ms.rounded()), 0, .zero, .zero) }

    private func record(_ kind: String, _ dx: Int, _ dy: Int, _ c: CGPoint, _ p: CGPoint) {
        guard let trace else { return }
        trace.seekToEndOfFile()
        trace.write(Data(String(format: "%.4f,%@,%d,%d,%.0f,%.0f,%.0f,%.0f\n", uptimeNow(), kind, dx, dy, c.x, c.y, p.x, p.y).utf8))
    }
    private var boundsCheckedAt = 0.0

    private func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// The cursor must stay inside the frontmost app's window. While the game hides the cursor it still has a screen
    /// position (synthetic events move it); if it wandered onto another window, a synthetic click there would steal focus
    /// from the game (camera "stuck", movement keys stuck because their key-up goes to the other app).
    private func allowedBounds() -> CGRect {
        let now = uptimeNow()
        if now - boundsCheckedAt > 0.5 {   // ponytail: 2 Hz poll; window moves/resizes are rare during play
            boundsCheckedAt = now
            bounds = frontWindowBounds() ?? CGDisplayBounds(CGMainDisplayID())
        }
        return bounds
    }

    private func frontWindowBounds() -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict), r.width > 100, r.height > 100 else { continue }
            // Stay well away from the edges: a click near the top landed on (or next to) the title bar, after which the
            // game stopped taking downward motion (seen live). The inventory is centred, so the inner area suffices.
            let top = max(80, r.height * 0.15), side = r.width * 0.05, bottom = r.height * 0.05
            return CGRect(x: r.minX + side, y: r.minY + top, width: r.width - 2 * side, height: r.height - top - bottom)
        }
        return nil
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        let b = allowedBounds()
        return CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
    }

    func move(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        // In relative mode the game reads the deltas; in the inventory it reads the (clamped) location.
        let c = cursor()
        let p = clamped(CGPoint(x: c.x + CGFloat(dx), y: c.y + CGFloat(dy)))
        let type: CGEventType = leftDown ? .leftMouseDragged : rightDown ? .rightMouseDragged : .mouseMoved
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p,
                        mouseButton: rightDown && !leftDown ? .right : .left)
        e?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        e?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        let posting = uptimeNow()
        e?.post(tap: .cghidEventTap)
        if trace != nil, uptimeNow() - posting > 0.003 { note("post_slow", ms: (uptimeNow() - posting) * 1000) }
        record("move", dx, dy, c, p)
    }

    func button(left: Bool, down: Bool) {
        guard (left ? leftDown : rightDown) != down else { return }
        let type: CGEventType = left ? (down ? .leftMouseDown : .leftMouseUp) : (down ? .rightMouseDown : .rightMouseUp)
        let c = cursor(), p = clamped(c)
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: left ? .left : .right)
        e?.setIntegerValueField(.mouseEventClickState, value: 1)
        e?.post(tap: .cghidEventTap)
        record(left ? (down ? "lmb_down" : "lmb_up") : (down ? "rmb_down" : "rmb_up"), 0, 0, c, p)
        if left { leftDown = down } else { rightDown = down }
    }

    func scroll(_ lines: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    func releaseAll() {
        button(left: true, down: false)
        button(left: false, down: false)
    }
}

/// Global hotkey through Carbon: needs no Input Monitoring permission. The key is swallowed system-wide.
/// Global hotkeys through one active event tap on the session key stream (needs Accessibility, which MinePointer has anyway).
/// Not Carbon RegisterEventHotKey: that needs NSApplication, and a registered background app is woken only every ~100 ms
/// while a fullscreen game is frontmost (choppy camera), so MinePointer runs a plain run loop. The matched key-down and its
/// key-up are swallowed, so the game never sees them (as with Carbon); autorepeats are swallowed without firing again.
final class HotKey {
    private struct Entry { let keyCode: Int64; let flags: CGEventFlags; let action: () -> Void }
    private static var entries: [Entry] = []
    private static var swallowed: Set<Int64> = []      // key codes whose key-up must not reach the game
    private static var tap: CFMachPort?
    private static let checked: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

    /// `modifiers` uses the Carbon constants (controlKey | optionKey ...), matched exactly.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        guard HotKey.installIfNeeded() else { return nil }
        var flags: CGEventFlags = []
        if modifiers & controlKey != 0 { flags.insert(.maskControl) }
        if modifiers & optionKey != 0 { flags.insert(.maskAlternate) }
        if modifiers & cmdKey != 0 { flags.insert(.maskCommand) }
        if modifiers & shiftKey != 0 { flags.insert(.maskShift) }
        HotKey.entries.append(Entry(keyCode: Int64(keyCode), flags: flags, action: action))
    }

    private static func installIfNeeded() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = HotKey.tap { CGEvent.tapEnable(tap: tap, enable: true) }    // the panic key must keep working
                return Unmanaged.passUnretained(event)
            }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyUp { return HotKey.swallowed.remove(code) != nil ? nil : Unmanaged.passUnretained(event) }
            let flags = event.flags.intersection(HotKey.checked)
            guard let entry = HotKey.entries.first(where: { $0.keyCode == code && $0.flags == flags }) else {
                return Unmanaged.passUnretained(event)
            }
            HotKey.swallowed.insert(code)
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { entry.action() }
            return nil
        }, userInfo: nil)
        guard let tap else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        return true
    }
}

/// Calls `onChange` with a freshly loaded config whenever config.json's modification date changes (1 s poll).
final class ConfigWatcher {
    private var lastModified: Date?
    private var timer: Timer?

    init(url: URL = configURL, onChange: @escaping (Config) -> Void) {
        lastModified = Self.modified(url)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let m = Self.modified(url)
            if m != self.lastModified {
                self.lastModified = m
                onChange(Config.load(from: url))
            }
        }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
