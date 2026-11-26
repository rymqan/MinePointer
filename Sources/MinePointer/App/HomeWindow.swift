import AppKit

// The main window (modelled on AirPointer's Home): what the engine is doing, what the person should do next, and the controls.
// It opens when the person launches MinePointer (not at login) and when they open it again while it runs. Like the setup
// window, the page is rebuilt when what it shows changes; @state lines that change nothing shown are ignored.

/// The sentence under the status chip: the next thing to do.
func homeGuidance(_ status: EngineStatus, _ state: EngineState, prompt: String) -> String {
    switch status {
    case .stopped: return "Stopped. Press Start to connect your case."
    case .failed(let text): return text
    case .crashLoop: return "The engine keeps crashing. The log is at \(EngineSupervisor.logURL.path)."
    case .running: break
    }
    if SessionText.waitsForLid(state.session) { return "Open the case lid, then close it again." }
    if state.mode == "calibrating" {
        return prompt.isEmpty ? "Put both earbuds in the case, close the lid and hold it in your right hand." : prompt
    }
    switch state.mode {
    case "output off": return "Output is off: the case moves nothing. Press ⌃⌥Space or Turn Output On."
    case "paused": return "Paused while the case lies flat. Pick it up to go on."
    case "reconnecting", "no stream": return "The stream dropped. Open the case lid, then close it again; MinePointer reconnects by itself."
    default: break
    }
    return state.session == "streaming" ? "Ready. Switch to Minecraft and play." : "Connecting to your AirPods…"
}

final class HomeWindow: NSObject {
    private let window: NSWindow
    private let supervisor: EngineSupervisor
    private unowned let app: AppDelegate
    private let actions = ActionStore()
    private let page = rkVStack(spacing: 16, align: .centerX)
    private var prompt = ""
    private var shown: [String] = []        // what the page showed last; a rebuild only when it differs

    init(supervisor: EngineSupervisor, app: AppDelegate) {
        self.supervisor = supervisor
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "MinePointer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.backgroundColor = HomePalette.canvas
        if let content = window.contentView {
            rkPin(page, in: content, insets: NSEdgeInsets(top: 48, left: 32, bottom: 24, right: 32))
        }
        supervisor.observe { [weak self] event in
            guard let self else { return }
            if case .message(.prompt(let text)) = event { prompt = text }
            if case .message(.calibrated) = event { prompt = "" }
            if case .status = event { prompt = "" }        // a new or stopped engine: the last one's step is stale
            if window.isVisible { render() }
        }
    }

    func show() {
        render(force: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func render(force: Bool = false) {
        let status = supervisor.status, state = supervisor.state
        let running = status == .running
        let icon = MenuIcon.of(status, state)
        let chipText = menuStatusText(status, state)
        let guidance = homeGuidance(status, state, prompt: prompt)
        let key = [chipText, guidance, icon.symbol, state.output ? "1" : "0", app.indicator.isEnabled ? "1" : "0"]
        guard force || key != shown else { return }
        shown = key

        actions.removeAll()
        page.arrangedSubviews.forEach { $0.removeFromSuperview() }
        page.addArrangedSubview(rkSymbolView(icon.symbol, 44, .labelColor))
        page.addArrangedSubview(rkTitle("MinePointer", 22, align: .center))
        let chip = StatusChip()
        chip.set(chipText, live: icon == .running)
        page.addArrangedSubview(chip)
        let text = rkWrap(guidance, 15, .labelColor)
        text.alignment = .center
        text.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
        page.addArrangedSubview(text)
        page.addArrangedSubview(rkSpacer())

        let primary = actions.bind(RemoteButton(running ? "Stop" : "Start", style: .primary, height: 44)) { [weak self] _ in
            guard let self else { return }
            if supervisor.status == .running { supervisor.stop() } else { supervisor.start() }
        }
        primary.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        page.addArrangedSubview(primary)

        let recalibrate = actions.bind(RemoteButton("Recalibrate", style: .secondary, height: 32)) { [weak self] _ in
            self?.supervisor.send(.recalibrate)
        }
        let output = actions.bind(RemoteButton(state.output ? "Turn Output Off" : "Turn Output On", style: .secondary, height: 32)) { [weak self] _ in
            guard let self else { return }
            supervisor.send(supervisor.state.output ? .outputOff : .outputOn)
        }
        recalibrate.isEnabled = running
        output.isEnabled = running
        page.addArrangedSubview(rkHStack([recalibrate, output], spacing: 8))

        let links: [(String, () -> Void)] = [
            ("Settings", { [weak self] in self?.app.showSettings() }),
            ("Sandbox", { [weak self] in self?.app.showSandbox() }),
            ("Run Setup Again", { [weak self] in self?.window.close(); self?.app.showSetup() }),
            ("Open Logs Folder", { NSWorkspace.shared.open(logsFolder) }),
        ]
        page.addArrangedSubview(rkHStack(links.map { link in
            actions.bind(RemoteButton(link.0, style: .tertiary, height: 28)) { _ in link.1() }
        }, spacing: 4))
        page.addArrangedSubview(rkLabel("⌃⌥Space turns output off and on · ⌃⌥C recalibrates", 11, .regular, .secondaryLabelColor))
    }
}
