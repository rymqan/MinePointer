import AppKit

// The menu bar item: an SF Symbol that follows the engine, and the menu.

enum MenuIcon: Equatable {
    case running, attention, error, stopped

    /// Running means playing: connected and no mode. Any other state of a running engine asks for a look.
    static func of(_ status: EngineStatus, _ state: EngineState) -> MenuIcon {
        switch status {
        case .stopped: return .stopped
        case .failed, .crashLoop: return .error
        case .running: return state.session == "streaming" && state.mode.isEmpty ? .running : .attention
        }
    }

    var symbol: String {
        switch self {
        case .running: return symbolName("cursorarrow.motionlines", "cursorarrow.rays", "cursorarrow")
        case .attention: return symbolName("ellipsis.circle", "pause.circle", "circle")
        case .error: return symbolName("exclamationmark.triangle", "exclamationmark.circle", "circle")
        case .stopped: return symbolName("cursorarrow.slash", "cursorarrow", "circle")
        }
    }

    var label: String {
        switch self {
        case .running: return "MinePointer, running"
        case .attention: return "MinePointer, needs attention"
        case .error: return "MinePointer, error"
        case .stopped: return "MinePointer, stopped"
        }
    }
}

/// The status row of the menu.
func menuStatusText(_ status: EngineStatus, _ state: EngineState) -> String {
    switch status {
    case .stopped: return "Stopped"
    case .failed(let text): return "Stopped: " + (text.count > 70 ? String(text.prefix(69)) + "…" : text)
    case .crashLoop: return "The engine keeps crashing"
    case .running: return SessionText.line(state)
    }
}

final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let supervisor: EngineSupervisor
    private unowned let app: AppDelegate

    init(app: AppDelegate) {
        self.app = app
        supervisor = app.supervisor
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        supervisor.observe { [weak self] _ in self?.updateIcon() }
        updateIcon()
    }

    private func updateIcon() {
        let icon = MenuIcon.of(supervisor.status, supervisor.state)
        let image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: icon.label)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.setAccessibilityLabel(icon.label)
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = supervisor.status, running = status == .running
        let row = NSMenuItem(title: menuStatusText(status, supervisor.state), action: nil, keyEquivalent: "")
        row.isEnabled = false
        if case .failed(let text) = status { row.toolTip = text }
        menu.addItem(row)
        menu.addItem(.separator())

        add(menu, running ? "Stop" : "Start", #selector(toggleEngine))
        add(menu, "Recalibrate", #selector(recalibrate), key: "c", modifiers: [.control, .option]).isEnabled = running
        let outputOff = !supervisor.state.output
        add(menu, outputOff ? "Turn Output On" : "Turn Output Off", #selector(toggleOutput), key: " ", modifiers: [.control, .option]).isEnabled = running
        add(menu, "Show Indicator", #selector(toggleIndicator)).state = app.indicator.isEnabled ? .on : .off
        menu.addItem(.separator())

        add(menu, "Setup…", #selector(showSetup))
        add(menu, "Settings…", #selector(showSettings), key: ",")
        add(menu, "Open Logs Folder", #selector(openLogs))
        add(menu, "Launch at Login", #selector(toggleLaunchAtLogin)).state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(.separator())

        add(menu, "About MinePointer", #selector(showAbout))
        add(menu, "Quit MinePointer", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        menu.addItem(item)
        return item
    }

    @objc private func toggleEngine() {
        if supervisor.status == .running { supervisor.stop() } else { supervisor.holdOutputOff = false; supervisor.start() }
    }
    @objc private func recalibrate() { supervisor.send(.recalibrate) }
    @objc private func toggleOutput() { supervisor.send(supervisor.state.output ? .outputOff : .outputOn) }
    @objc private func toggleIndicator() { app.setIndicator(!app.indicator.isEnabled) }
    @objc private func showSetup() { app.showSetup() }
    @objc private func showSettings() { app.showSettings() }
    @objc private func openLogs() { NSWorkspace.shared.open(logsFolder) }
    @objc private func toggleLaunchAtLogin() { app.setLaunchAtLogin(!LaunchAtLogin.isEnabled) }
    @objc private func showAbout() { app.showAbout() }
    @objc private func quit() { NSApp.terminate(nil) }
}
