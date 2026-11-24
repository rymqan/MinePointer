import AppKit
import ServiceManagement

// Small helpers shared by the UI files: raw config access, symbol lookup, "Launch at Login", an ink switch.

/// config.json as it is on disk (it may hold keys the Config struct does not know yet, such as record_sessions).
func readConfigRaw() -> [String: Any] {
    ((try? Data(contentsOf: configURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

func configBool(_ key: String, default value: Bool = false) -> Bool {
    readConfigRaw()[key] as? Bool ?? value
}

/// The first SF Symbol name this macOS knows, so a missing symbol never leaves a hole in the UI.
func symbolName(_ candidates: String...) -> String {
    candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "circle"
}

func openSettingsURL(_ string: String) {
    if let url = URL(string: string) { NSWorkspace.shared.open(url) }
}

let bluetoothSettingsURL = "x-apple.systempreferences:com.apple.BluetoothSettings"
let inputMonitoringSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers or unregisters; when macOS wants the user's approval it opens the Login Items pane.
    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Keeps the closures behind target-action controls alive: `bind` sets the control's target and action.
final class ActionStore: NSObject {
    private var handlers: [(NSControl) -> Void] = []

    @discardableResult
    func bind<T: NSControl>(_ control: T, _ handler: @escaping (T) -> Void) -> T {
        handlers.append { handler($0 as! T) }
        control.tag = handlers.count - 1
        control.target = self
        control.action = #selector(fire(_:))
        return control
    }
    func removeAll() { handlers = [] }
    @objc private func fire(_ sender: NSControl) { handlers[sender.tag](sender) }
}

/// An ink on/off switch (NSSwitch can only draw in the system accent color; the design system forbids it).
final class AppSwitch: NSView {
    var onChange: ((Bool) -> Void)?
    private(set) var isOn = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func setOn(_ on: Bool) { guard on != isOn else { return }; isOn = on }
    private func toggle() { isOn.toggle(); onChange?(isOn); NSAccessibility.post(element: self, notification: .valueChanged) }
    override func mouseDown(with event: NSEvent) { toggle() }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 { toggle() } else { super.keyDown(with: event) }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill() }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2 - 0.5, yRadius: bounds.height / 2 - 0.5)
        (isOn ? HomePalette.ink : HomePalette.track).setFill(); track.fill()
        let side = bounds.height - 4
        let knob = NSRect(x: isOn ? bounds.width - 2 - side : 2, y: 2, width: side, height: side)
        (isOn ? HomePalette.canvas : NSColor.white).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .switch }
    override func accessibilityValue() -> Any? { NSNumber(value: isOn ? 1 : 0) }
    override func accessibilityPerformPress() -> Bool { toggle(); return true }
}
