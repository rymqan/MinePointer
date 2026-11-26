import AppKit

// Settings: Camera, Gestures, General. Every change is written to config.json (read-merge-write, debounced); the engine's
// ConfigWatcher picks it up within a second. Calibration keys (neutral_up, forward_axis) are never touched here.

/// One labelled slider and how it maps to a config value: shown = config × scale, snapped to `step` and clamped.
struct SliderSetting {
    let key: String
    let title: String
    let caption: String?
    let unit: String
    let path: KeyPath<Config, Double>
    let lower: Double, upper: Double, step: Double
    var scale = 1.0
    var decimals = 0

    func shown(fromConfig value: Double) -> Double { clamp(snap(value * scale)) }
    func config(fromShown value: Double) -> Double { ((clamp(snap(value)) / scale) * 1e6).rounded() / 1e6 }
    var defaultShown: Double { shown(fromConfig: Config()[keyPath: path]) }
    func text(_ shown: Double) -> String { String(format: "%.\(decimals)f", shown) + unit }

    private func snap(_ v: Double) -> Double { (v / step).rounded() * step }
    private func clamp(_ v: Double) -> Double { min(upper, max(lower, v)) }

    static let camera: [SliderSetting] = [
        SliderSetting(key: "mc_sensitivity", title: "Minecraft mouse sensitivity", caption: "Set the same value in Minecraft’s own slider (Options, Controls, Mouse Settings).",
                      unit: "%", path: \.mcSensitivity, lower: 0, upper: 200, step: 1, scale: 200),
        SliderSetting(key: "gain", title: "Camera speed", caption: "Degrees the view turns per degree you turn the case.",
                      unit: "×", path: \.gain, lower: 1, upper: 6, step: 0.1, decimals: 1),
        SliderSetting(key: "deadzone_dps", title: "Deadzone", caption: "Slow drift below this turn rate is ignored.",
                      unit: " °/s", path: \.deadzoneDps, lower: 0, upper: 15, step: 0.5, decimals: 1),
        SliderSetting(key: "one_euro_min_cutoff", title: "Smoothing", caption: "Lower is smoother but lags more.",
                      unit: " Hz", path: \.oneEuroMinCutoff, lower: 0.3, upper: 3, step: 0.05, decimals: 2),
    ]

    static let gestures: [SliderSetting] = [
        SliderSetting(key: "jerk_onset_g", title: "Jerk down", caption: "Left click. Lower is more sensitive.",
                      unit: " g", path: \.jerkOnsetG, lower: 0.5, upper: 1.2, step: 0.05, decimals: 2),
        SliderSetting(key: "jerk_up_onset_g", title: "Jerk up", caption: "Right click. Lower is more sensitive.",
                      unit: " g", path: \.jerkUpOnsetG, lower: 0.6, upper: 1.4, step: 0.05, decimals: 2),
        SliderSetting(key: "pull_onset_g", title: "Pull toward you", caption: "Holds the right button. Lower is more sensitive.",
                      unit: " g", path: \.pullOnsetG, lower: 0.5, upper: 1.2, step: 0.05, decimals: 2),
        SliderSetting(key: "twist_peak_dps", title: "Twist", caption: "Changes the slot. Lower is more sensitive.",
                      unit: " °/s", path: \.twistPeakDps, lower: 150, upper: 500, step: 10),
        SliderSetting(key: "click_hold_ms", title: "Click length", caption: "How long a click holds the button. At 250 ms or more, one click can break two blocks in creative mode.",
                      unit: " ms", path: \.clickHoldMs, lower: 50, upper: 240, step: 10),
        SliderSetting(key: "pause_tilt_deg", title: "Pause tilt", caption: "How far the case must tilt from your grip, and lie still, to pause.",
                      unit: "°", path: \.pauseTiltDeg, lower: 45, upper: 80, step: 1),
    ]

    static var all: [SliderSetting] { camera + gestures }
}

/// The keys the window exposes besides the sliders, with the values "Reset to defaults" writes. Never calibration keys.
func settingsDefaults() -> [String: Any] {
    var values: [String: Any] = [:]
    for setting in SliderSetting.all { values[setting.key] = Config()[keyPath: setting.path] }
    values["invert_y"] = Config().invertY
    values["scroll_next_sign"] = Config().scrollNextSign
    values["indicator"] = Config().indicator
    values["record_sessions"] = false
    values[AppIconChoice.configKey] = AppIconChoice.green.rawValue
    return values
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private unowned let app: AppDelegate
    private let actions = ActionStore()
    private let tabs = NSSegmentedControl(labels: ["Camera", "Gestures", "General"], trackingMode: .selectOne, target: nil, action: nil)
    private let holder = NSView()
    private var pages: [NSView] = []
    private var reloaders: [() -> Void] = []
    private var pending: [String: Any] = [:]
    private var timer: Timer?

    init(app: AppDelegate) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "MinePointer Settings"
        window.isReleasedWhenClosed = false
        window.backgroundColor = HomePalette.canvas
        window.delegate = self
        guard let content = window.contentView else { return }
        tabs.selectedSegment = 0
        tabs.segmentStyle = .texturedRounded
        tabs.translatesAutoresizingMaskIntoConstraints = false
        actions.bind(tabs) { [weak self] control in self?.select(control.selectedSegment) }
        holder.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        content.addSubview(holder)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            tabs.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            holder.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            holder.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            holder.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        pages = [cameraPage(), gesturesPage(), generalPage()]
        select(0)
    }

    func show() {
        reload()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) { flush() }

    private func select(_ index: Int) {
        tabs.selectedSegment = index
        for view in holder.subviews { view.removeFromSuperview() }
        let page = pages[index]
        rkPin(page, in: holder)
    }

    private func reload() { for reload in reloaders { reload() } }

    // MARK: writing

    private func change(_ key: String, _ value: Any) {
        pending[key] = value
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in self?.flush() }
    }

    private func flush() {
        timer?.invalidate(); timer = nil
        guard !pending.isEmpty else { return }
        let changes = pending
        pending = [:]
        do { try updateConfigFile(changes) } catch { app.supervisor.note("could not write config.json: \(error.localizedDescription)") }
    }

    // MARK: pages

    private func cameraPage() -> NSView {
        let invert = switchRow("Invert Y", "Moving the far end of the case up looks down instead.", key: "invert_y")
        return scrollPage(SliderSetting.camera.map(sliderRow) + [invert])
    }

    private func gesturesPage() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["Clockwise twist = next slot", "Clockwise twist = previous slot"])
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setAccessibilityLabel("Scroll direction")
        actions.bind(popup) { [weak self] control in self?.change("scroll_next_sign", control.indexOfSelectedItem == 0 ? -1 : 1) }
        reloaders.append { popup.selectItem(at: Config.load().scrollNextSign < 0 ? 0 : 1) }
        let scroll = rkVStack([rkLabel("Scroll direction", 13, .semibold), popup], spacing: 6, align: .leading)
        var rows = SliderSetting.gestures.map(sliderRow)
        rows.insert(scroll, at: 4)
        return scrollPage(rows)
    }

    private func generalPage() -> NSView {
        let indicator = switchRow("Show indicator", "A small panel at the top right of the screen with the held buttons and the last gesture.", key: nil,
                                  read: { configBool("indicator") }, write: { [weak self] on in self?.app.setIndicator(on) })
        let login = switchRow("Launch at login", "Start MinePointer when you log in.", key: nil,
                              read: { LaunchAtLogin.isEnabled }, write: { [weak self] on in self?.app.setLaunchAtLogin(on) })
        let record = switchRow("Record raw sensor sessions", "For debugging; about 100 MB per hour.", key: "record_sessions")
        let icon = appIconRow()
        let reset = actions.bind(RemoteButton("Reset to Defaults…", style: .secondary, height: 32)) { [weak self] _ in self?.confirmReset() }
        let openConfig = actions.bind(RemoteButton("Open config.json", style: .secondary, height: 32)) { _ in
            Config.writeDefaultsIfMissing()
            NSWorkspace.shared.open(configURL)
        }
        let buttons = rkHStack([reset, openConfig], spacing: 8)
        let note = rkWrap("Reset only changes the settings on these tabs; your calibration stays. config.json holds every other setting.", 12)
        let paths = rkVStack([rkLabel("Folders", 13, .semibold), pathRow("Config", configURL), pathRow("Logs", logsFolder)], spacing: 6, align: .leading)
        return scrollPage([icon, indicator, login, record, buttons, note, paths])
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset settings to their defaults?"
        alert.informativeText = "This changes the settings on these tabs back to their defaults. Your calibration stays."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.resetDefaults() }
        }
    }

    private func resetDefaults() {
        let defaults = settingsDefaults()
        flush()
        try? updateConfigFile(defaults)
        app.indicator.setEnabled(false)
        AppIconChoice.green.apply()
        reload()
    }

    // MARK: rows

    private func sliderRow(_ setting: SliderSetting) -> NSView {
        let slider = NSSlider(value: setting.defaultShown, minValue: setting.lower, maxValue: setting.upper, target: nil, action: nil)
        slider.trackFillColor = HomePalette.ink
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setAccessibilityLabel(setting.title)
        if let caption = setting.caption { slider.setAccessibilityHelp(caption) }
        let value = rkLabel("", 13, .medium)
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        value.alignment = .right
        actions.bind(slider) { [weak self] control in
            let shown = setting.config(fromShown: control.doubleValue)
            value.stringValue = setting.text(setting.shown(fromConfig: shown))
            control.setAccessibilityValueDescription(value.stringValue)
            self?.change(setting.key, shown)
        }
        reloaders.append {
            let shown = setting.shown(fromConfig: Config.load()[keyPath: setting.path])
            slider.doubleValue = shown
            value.stringValue = setting.text(shown)
            slider.setAccessibilityValueDescription(value.stringValue)
        }
        var views: [NSView] = [rkHStack([rkLabel(setting.title, 13, .semibold), rkSpacer(), value], spacing: 8), slider]
        if let caption = setting.caption { views.append(rkWrap(caption, 12)) }
        let stack = rkVStack(views, spacing: 4, align: .leading)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    /// A switch with a title and a caption. With `key` it reads and writes that config key; otherwise `read` and `write` do it.
    private func switchRow(_ title: String, _ caption: String, key: String?, read: (() -> Bool)? = nil, write: ((Bool) -> Void)? = nil) -> NSView {
        let toggle = AppSwitch()
        toggle.setAccessibilityLabel(title)
        toggle.onChange = { [weak self] on in
            if let key { self?.change(key, on) } else { write?(on) }
        }
        reloaders.append { toggle.setOn(read?() ?? configBool(key ?? "")) }
        let words = rkVStack([rkLabel(title, 13, .semibold), rkWrap(caption, 12)], spacing: 2, align: .leading)
        let row = rkHStack([words, rkSpacer(), toggle], spacing: 12)
        words.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, constant: -60).isActive = true
        return row
    }

    /// The app icon picker: every variant with a small preview; a pick changes the icon in Finder at once.
    private func appIconRow() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setAccessibilityLabel("App icon")
        for choice in AppIconChoice.allCases {
            popup.addItem(withTitle: choice.title)
            let preview = choice.image?.copy() as? NSImage
            preview?.size = NSSize(width: 18, height: 18)
            popup.lastItem?.image = preview
        }
        let error = rkWrap("", 12)
        error.textColor = .systemRed
        error.isHidden = true
        // A pick is saved at once (not debounced), and only when Finder took it, so config.json and Finder always agree.
        actions.bind(popup) { [weak self] control in
            let choice = AppIconChoice.allCases[control.indexOfSelectedItem]
            if let problem = choice.apply() {
                popup.selectItem(at: AppIconChoice.allCases.firstIndex(of: .current) ?? 0)
                error.stringValue = problem
                error.isHidden = false
            } else {
                error.isHidden = true
                self?.change(AppIconChoice.configKey, choice.rawValue)
                self?.flush()
            }
        }
        reloaders.append {
            popup.selectItem(at: AppIconChoice.allCases.firstIndex(of: .current) ?? 0)
            error.isHidden = true
        }
        return rkVStack([rkLabel("App icon", 13, .semibold), popup, rkWrap("Shown in Finder and Launchpad. Finder may take a few seconds to update.", 12), error],
                        spacing: 6, align: .leading)
    }

    private func pathRow(_ name: String, _ url: URL) -> NSView {
        let path = rkWrap("\(name): \((url.path as NSString).abbreviatingWithTildeInPath)", 12)
        path.isSelectable = true
        return path
    }

    /// A page: its rows stacked in a scroll view, 24 pt from the sides.
    private func scrollPage(_ rows: [NSView]) -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = RemoteFlipped()
        document.translatesAutoresizingMaskIntoConstraints = false
        let stack = rkVStack(rows, spacing: 20, align: .leading)
        rkPin(stack, in: document, insets: NSEdgeInsets(top: 12, left: 24, bottom: 24, right: 24))
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        scroll.documentView = document
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])
        return scroll
    }
}
