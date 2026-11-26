import AppKit

// A model of the case that follows the real one (the engine's `@pose` lines), with the gesture it last recognized: a place to try
// the motions with nothing clicked; during a calibration it shows the step's motion instead. While the window is open the engine sends poses and its output is held off (EngineSupervisor);
// closing it releases the hold.

final class SandboxWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let supervisor: EngineSupervisor
    private let actions = ActionStore()
    private let model = CaseDemoView()
    private let gesture = rkTitle("", 22, align: .center)
    private let status = rkWrap("", 13, align: .center)
    private let start = RemoteButton("Start", style: .primary, height: 40)
    private var gestureSeq = 0
    private var prompt: String?             // the calibration step running now: the model shows its motion instead of the case

    init(supervisor: EngineSupervisor) {
        self.supervisor = supervisor
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Sandbox"
        window.titleVisibility = .hidden        // the page shows the title
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.backgroundColor = HomePalette.canvas
        window.delegate = self
        let page = rkVStack([
            rkTitle("Sandbox", 26, align: .center),
            rkWrap("The model follows your case. Nothing is clicked while this window is open.", 14, align: .center),
            model, gesture, status, start, rkSpacer(),
        ], spacing: 12, align: .centerX)
        model.heightAnchor.constraint(equalToConstant: 300).isActive = true
        for view in page.arrangedSubviews where !(view is RemoteButton) { view.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        model.setAccessibilityLabel("A model of your case, moving as you move it")
        actions.bind(start) { [weak self] _ in self?.supervisor.start() }
        if let content = window.contentView { rkPin(page, in: content, insets: NSEdgeInsets(top: 44, left: 32, bottom: 24, right: 32)) }
        supervisor.onPose = { [weak self] values in self?.model.follow(values) }
        supervisor.observe { [weak self] event in self?.engineEvent(event) }
    }

    func show() {
        if !window.isVisible {
            supervisor.holdOutput("sandbox")
            supervisor.wantsPoses = true
            gestureSeq = supervisor.state.seq
            gesture.stringValue = " "
            window.center()
        }
        update()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func engineEvent(_ event: EngineEvent) {
        guard window.isVisible else { return }
        switch event {
        case .message(.prompt(let text)):
            prompt = text
            model.clip = SetupFlow.calibrationNumber(text).flatMap(SetupFlow.calibrationClip)
        case .message(.calibrated), .status:
            prompt = nil
            model.clip = nil
        case .message(.state(let state)) where state.seq != gestureSeq:
            gestureSeq = state.seq
            gesture.stringValue = state.gesture
            if !state.gesture.isEmpty {
                NSAccessibility.post(element: window, notification: .announcementRequested,
                                     userInfo: [.announcement: state.gesture, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
            let shown = state.seq
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if self?.gestureSeq == shown { self?.gesture.stringValue = " " }
            }
        default: break
        }
        update()
    }

    private func update() {
        let running = supervisor.status == .running
        let session = supervisor.state.session
        rkSetText(status, !running ? "MinePointer isn’t running. Start it, then hold the case the way you play."
                  : session != "streaming" ? SessionText.session(session)
                  : prompt ?? (supervisor.state.mode == "calibrating" ? "Calibrating…" : ""))
        start.isHidden = running
    }

    func windowWillClose(_ notification: Notification) {
        supervisor.wantsPoses = false
        supervisor.releaseOutput("sandbox")
    }
}
