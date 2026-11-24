import AppKit

// The on-screen panel (held buttons, last gesture, mode) in the UI process, fed by the supervisor. The UI process is throttled
// while a fullscreen game is frontmost; a lagging panel does not matter, the engine's camera is another process.

private let gestureSeconds = 1.2      // how long the last gesture stays on the panel
private let margin: CGFloat = 12      // from the top right screen corner, outside the cursor clamp area (top 15% of the window)

final class IndicatorPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")      // empty, so the first render lays the panel out
    private let supervisor: EngineSupervisor
    private var enabled = configBool("indicator")
    private var shownSeq = 0
    private var gestureUntil = 0.0
    private var timer: Timer?
    private var prompt = ""                 // the calibration step at every start: the only place it shows over the game

    init(supervisor: EngineSupervisor) {
        self.supervisor = supervisor
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 26), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        panel.hasShadow = false
        panel.ignoresMouseEvents = true          // a synthetic click must never land here or take focus from the game
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        panel.contentView?.addSubview(label)
        supervisor.observe { [weak self] event in
            guard let self else { return }
            if case .message(.state(let state)) = event, state.seq != shownSeq { shownSeq = state.seq; gestureUntil = uptimeNow() + gestureSeconds }
            if case .message(.prompt(let text)) = event { prompt = text }
            if case .message(.calibrated) = event { prompt = "" }
            refresh()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.label.stringValue = ""; self?.render()
        }
        refresh()
    }

    var isEnabled: Bool { enabled }

    /// The `indicator` config key changed (menu or settings).
    func setEnabled(_ on: Bool) { enabled = on; refresh() }

    private var calibrating: Bool { supervisor.state.mode == "calibrating" }
    /// Calibration and a dropped stream show even with the indicator off: the grip wizard runs at every start and the lid
    /// prompt comes every ~30 min, usually with the game in front, where the panel is the only thing visible.
    private var needsPerson: Bool { calibrating || ["reconnecting", "no stream"].contains(supervisor.state.mode) }
    private var wanted: Bool { (enabled || needsPerson) && supervisor.status == .running }

    private func refresh() {
        if wanted {
            render()
            panel.orderFrontRegardless()
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.render() }     // expires the gesture text
            }
        } else {
            panel.orderOut(nil)
            timer?.invalidate(); timer = nil
        }
    }

    private func render() {
        let state = supervisor.state
        let text = calibrating && !prompt.isEmpty ? "calibrating · " + prompt
            : state.mode == "reconnecting" ? SessionText.line(state)
            : state.text(showGesture: uptimeNow() < gestureUntil)
        guard text != label.stringValue else { return }
        label.stringValue = text
        let size = label.fittingSize
        label.frame = NSRect(x: 8, y: 4, width: size.width, height: size.height)
        guard let screen = NSScreen.main?.frame else { return }
        let w = size.width + 16, h = size.height + 8
        panel.setFrame(NSRect(x: screen.maxX - w - margin, y: screen.maxY - h - margin, width: w, height: h), display: true)
    }
}
