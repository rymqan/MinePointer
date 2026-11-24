// Output check: drives the mouse from global hotkeys, no sensors.
// Build: swiftc -O -swift-version 5 tools/mousetest.swift -o build/mousetest
// Run:   build/mousetest [pixels-per-tick] [--session]
//   arrows = move (camera), J = hold LMB, K = hold RMB, U / I = scroll +1 / -1, \ = release all and quit.
import AppKit
import Carbon.HIToolbox
import GameController

let args = CommandLine.arguments.dropFirst()
let step = Int(args.first { Int($0) != nil } ?? "") ?? 6
let tap: CGEventTapLocation = args.contains("--session") ? .cgSessionEventTap : .cghidEventTap

var heldArrows = Set<Int>()
var leftDown = false, rightDown = false

func cursor() -> CGPoint { CGEvent(source: nil)!.location }

func move(dx: Int, dy: Int) {
    let c = cursor(), b = CGDisplayBounds(CGMainDisplayID())  // ponytail: main display only
    let p = CGPoint(x: min(max(c.x + CGFloat(dx), b.minX), b.maxX - 1),
                    y: min(max(c.y + CGFloat(dy), b.minY), b.maxY - 1))
    let type: CGEventType = leftDown ? .leftMouseDragged : rightDown ? .rightMouseDragged : .mouseMoved
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: rightDown && !leftDown ? .right : .left)
    e?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
    e?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
    e?.post(tap: tap)
}

func button(left: Bool, down: Bool) {
    guard (left ? leftDown : rightDown) != down else { return }  // ignore key auto-repeat
    let type: CGEventType = left ? (down ? .leftMouseDown : .leftMouseUp) : (down ? .rightMouseDown : .rightMouseUp)
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursor(), mouseButton: left ? .left : .right)
    e?.setIntegerValueField(.mouseEventClickState, value: 1)
    e?.post(tap: tap)
    if left { leftDown = down } else { rightDown = down }
}

func scroll(_ lines: Int32) {
    CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)?.post(tap: tap)
}

func releaseAll() {
    button(left: true, down: false)
    button(left: false, down: false)
    heldArrows.removeAll()
}

func handle(_ key: Int, pressed: Bool) {
    print(pressed ? "down" : "up  ", key)
    switch key {
    case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
        if pressed { heldArrows.insert(key) } else { heldArrows.remove(key) }
    case kVK_ANSI_J: button(left: true, down: pressed)
    case kVK_ANSI_K: button(left: false, down: pressed)
    case kVK_ANSI_U: if pressed { scroll(1) }
    case kVK_ANSI_I: if pressed { scroll(-1) }
    case kVK_ANSI_Backslash: if pressed { releaseAll(); exit(0) }
    default: break
    }
}

// Global hotkeys via Carbon: no Input Monitoring permission needed. Registered keys are swallowed system-wide while running.
let keys = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_Backslash]
for k in keys {
    var ref: EventHotKeyRef?
    let st = RegisterEventHotKey(UInt32(k), 0, EventHotKeyID(signature: 0x50444346, id: UInt32(k)), GetApplicationEventTarget(), 0, &ref)
    if st != noErr { print("hotkey \(k) not registered: \(st)") }
}
var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
             EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &id)
    handle(Int(id.id), pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
    return noErr
}, 2, &specs, nil, nil)

Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
    var dx = 0, dy = 0
    if heldArrows.contains(kVK_LeftArrow) { dx -= step }
    if heldArrows.contains(kVK_RightArrow) { dx += step }
    if heldArrows.contains(kVK_UpArrow) { dy -= step }
    if heldArrows.contains(kVK_DownArrow) { dy += step }
    if dx != 0 || dy != 0 { move(dx: dx, dy: dy) }
}

// Ctrl-C also releases buttons.
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { releaseAll(); exit(0) }
sigint.resume()

// Diagnostics: SDL3 ignores NSEvent motion and buttons while any GCMouse exists.
NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { n in
    print("GCMouse connected: \((n.object as? GCMouse)?.vendorName ?? "?") (total \(GCMouse.mice().count))")
}
NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { _ in
    print("GCMouse disconnected (total \(GCMouse.mice().count))")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("GCMouse count after 2 s: \(GCMouse.mice().count)") }

let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
print("Accessibility trusted: \(trusted). step=\(step) tap=\(tap == .cghidEventTap ? "hid" : "session")")
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
