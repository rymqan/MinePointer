import AppKit
import ApplicationServices
import CoreBluetooth

// First run, one window, one step at a time (modelled on AirPointer's SetupAssistant). The whole page is rebuilt when
// something it shows changes: the steps are small and change a few times a second at most.
// While setup runs, the engine has `output off`, so the window never receives synthetic clicks or cursor moves.

final class SetupWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let supervisor: EngineSupervisor
    private unowned let app: AppDelegate
    private let actions = ActionStore()
    private let page = rkVStack(spacing: 16, align: .centerX)
    private let bluetooth = ClosedCaseBluetoothAccess()

    private var flow = SetupFlow()
    private var permissions = SetupPermissions()
    private var survey: ClosedCaseAirPods.Survey?
    private var surveyLoading = false
    private var selected: ClosedCaseAirPods?
    private var inputAsked = false
    private var poll: Timer?
    private var vetoHintUntil = 0.0
    private var finished = false
    private var attempt = 0                 // bumped on every Connect and on leaving it: a restart scheduled for an old one does nothing
    private var awaitingEngine = false      // until the fresh engine runs, the outgoing one's messages must not move the flow

    init(supervisor: EngineSupervisor, app: AppDelegate) {
        self.supervisor = supervisor
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Set Up MinePointer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.backgroundColor = HomePalette.canvas
        window.delegate = self
        guard let content = window.contentView else { return }
        rkPin(page, in: content, insets: NSEdgeInsets(top: 56, left: 40, bottom: 28, right: 40))
        supervisor.observe { [weak self] event in self?.engineEvent(event) }
    }

    /// Opens at `step` (1-7) or at the welcome page; an open window keeps its place.
    func show(step: Int? = nil) {
        if !window.isVisible || step != nil {
            finished = false
            flow = SetupFlow()
            go(to: step.flatMap(SetupStep.init(rawValue:)) ?? .welcome)
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: flow

    private func go(to step: SetupStep) {
        flow.step = step
        supervisor.note("setup step: \(step)")
        enter(step)
        render()
    }

    private func enter(_ step: SetupStep) {
        poll?.invalidate(); poll = nil
        if step != .connect, awaitingEngine { attempt += 1; awaitingEngine = false }     // Back while the old engine stops
        switch step {
        case .permissions:
            permissions = Self.currentPermissions()
            poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                let now = Self.currentPermissions()
                if now != permissions { permissions = now; render() }
            }
        case .airpods:
            refreshSurvey()
        case .connect:
            // Setup must not move the cursor or click: output stays off until "Start playing".
            // A fresh engine every time: a running one may stream from another pair, and it is calibrated already.
            supervisor.holdOutputOff = true
            attempt += 1
            let mine = attempt
            awaitingEngine = true
            supervisor.stop { [weak self] in
                guard let self, mine == attempt, flow.step == .connect else { return }     // closing the window bumps the attempt
                awaitingEngine = false
                flow.prompt = nil; flow.calibrated = false; flow.lit = []
                supervisor.start()
            }
        default: break
        }
    }

    private func engineEvent(_ event: EngineEvent) {
        guard window.isVisible else { return }
        if awaitingEngine, case .message = event { return }
        let before = flow
        switch event {
        case .message(let message): flow.apply(message)
        case .status: break
        }
        if flow.step != before.step {
            supervisor.note("setup step: \(flow.step)")
            enter(flow.step)
        }
        if flow.vetoes != before.vetoes {
            vetoHintUntil = uptimeNow() + 4
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) { [weak self] in
                if self?.flow.step == .gestures { self?.render() }
            }
        }
        if case .message(.state) = event, flow == before, flow.step != .connect { return }      // state lines arrive often; only the connect page shows them
        render()
    }

    private static func currentPermissions() -> SetupPermissions {
        SetupPermissions(bluetooth: CBManager.authorization == .allowedAlways, bluetoothAsked: CBManager.authorization != .notDetermined,
                         accessibility: AXIsProcessTrusted(), inputMonitoring: CGPreflightListenEventAccess())
    }

    private func refreshSurvey() {
        guard !surveyLoading else { return }
        surveyLoading = true
        render()
        ClosedCaseAirPods.survey { [weak self] result in
            guard let self else { return }
            surveyLoading = false
            survey = result
            if case .chosen(let pair) = ClosedCaseAirPods.choose(result, saved: ClosedCaseAirPods.saved), !pair.usesHeadphoneMotion { selected = pair } else { selected = nil }
            render()
        }
    }

    // MARK: rendering

    private struct Page {
        var symbol: String
        var title: String
        var body: String
        var content: NSView?
        var primary: String?
        var primaryEnabled = true
        var primaryAction: () -> Void = {}
        var extras: [(title: String, action: () -> Void)] = []
    }

    private func render() {
        actions.removeAll()
        for view in page.arrangedSubviews { page.removeArrangedSubview(view); view.removeFromSuperview() }
        let spec = pageSpec()
        page.addArrangedSubview(rkSymbolView(spec.symbol, 46, .labelColor, .light))
        let title = rkTitle(spec.title, 26, align: .center)
        let body = rkWrap(spec.body, 14, align: .center)
        for label in [title, body] { page.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        page.setCustomSpacing(8, after: title)
        page.setCustomSpacing(24, after: body)
        if let content = spec.content {
            page.addArrangedSubview(content)
            content.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        }
        page.addArrangedSubview(rkSpacer())
        if let primary = spec.primary {
            let button = actions.bind(RemoteButton(primary, style: .primary, height: 48)) { _ in spec.primaryAction() }
            button.isEnabled = spec.primaryEnabled
            if spec.primaryEnabled { button.keyEquivalent = "\r" }
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            page.addArrangedSubview(button)
        }
        var links = spec.extras
        if let back = SetupFlow.back(from: flow.step) {
            links.insert(("Back", { [weak self] in
                if back == .airpods { self?.supervisor.stop() }
                self?.go(to: back)
            }), at: 0)
        }
        if !links.isEmpty {
            let row = rkHStack(links.map { link in actions.bind(RemoteButton(link.title, style: .tertiary, height: 32)) { _ in link.action() } }, spacing: 8)
            page.addArrangedSubview(row)
        }
    }

    private func pageSpec() -> Page {
        switch flow.step {
        case .welcome: return welcomePage()
        case .permissions: return permissionsPage()
        case .airpods: return airPodsPage()
        case .connect: return connectPage()
        case .calibrate: return calibratePage()
        case .gestures: return gesturesPage()
        case .done: return donePage()
        }
    }

    private func next() -> () -> Void {
        let step = SetupStep(rawValue: flow.step.rawValue + 1) ?? .done
        return { [weak self] in self?.go(to: step) }
    }

    // MARK: pages

    private func welcomePage() -> Page {
        let list = rkVStack([
            row(symbolName("airpods.gen4", "airpods"), "AirPods 4 with Active Noise Cancellation, or another model AirPointer supports. AirPods Pro (1st generation) don’t work."),
            row(symbolName("gamecontroller", "cursorarrow"), "Minecraft Java Edition."),
            row(symbolName("keyboard"), "Your keyboard stays as it is: it still moves and jumps."),
            row(symbolName("speaker.slash", "speaker"), "While MinePointer is connected, your Mac plays sound itself instead of the AirPods."),
        ], spacing: 10, align: .leading)
        return Page(symbol: symbolName("airpods.gen4", "airpods"), title: "Aim with your AirPods case",
                    body: "Hold the closed case in your right hand. Turn it slowly to look around, move it sharply to click.",
                    content: list, primary: "Get started", primaryAction: next())
    }

    private func permissionsPage() -> Page {
        let p = permissions
        let btAction: () -> Void = { [weak self] in
            guard let self else { return }
            if CBManager.authorization == .notDetermined {
                bluetooth.request { [weak self] _ in self?.permissions = Self.currentPermissions(); self?.render() }
            } else if let url = ClosedCaseBluetoothAccess.settings { NSWorkspace.shared.open(url) }
        }
        let axAction: () -> Void = {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            AccessibilityGuide.shared.open()
        }
        let inputAction: () -> Void = { [weak self] in
            guard let self else { return }
            if inputAsked { openSettingsURL(inputMonitoringSettingsURL) } else { inputAsked = true; _ = CGRequestListenEventAccess() }
        }
        let rows = rkVStack([
            permissionRow(symbolName("dot.radiowaves.left.and.right", "antenna.radiowaves.left.and.right"), "Bluetooth", "To reach your AirPods.", p.bluetooth,
                          p.bluetoothAsked ? "Open Settings" : "Allow", btAction),
            permissionRow(symbolName("cursorarrow.click", "cursorarrow"), "Accessibility", "To move the camera and click in Minecraft.", p.accessibility, "Allow", axAction),
            permissionRow(symbolName("keyboard"), "Input Monitoring", "Recommended for the hotkeys (⌃⌥Space and ⌃⌥C). MinePointer works without it.", p.inputMonitoring,
                          inputAsked ? "Open Settings" : "Allow", inputAction),
        ], spacing: 10, align: .leading)
        return Page(symbol: symbolName("lock.shield", "lock"), title: "Allow access",
                    body: "MinePointer needs Bluetooth and Accessibility. Each one shows as allowed here the moment you turn it on.",
                    content: rows, primary: "Continue",
                    primaryEnabled: SetupFlow.canContinue(.permissions, permissions: p, hasAirPods: true), primaryAction: next())
    }

    private func airPodsPage() -> Page {
        let list = rkVStack(spacing: 10, align: .leading)
        var body = "Pick the pair you’ll use. It has to be paired with this Mac already."
        if surveyLoading && survey == nil {
            list.addArrangedSubview(rkLabel("Looking for paired AirPods…", 13, .regular, .secondaryLabelColor))
        } else if let survey {
            if !survey.poweredOn { body = "Bluetooth is off on this Mac. Turn it on, then press Refresh." }
            else if survey.pairs.isEmpty { body = "No paired AirPods found. Pair yours in Bluetooth settings, then press Refresh." }
            for pair in survey.pairs { list.addArrangedSubview(airPodsRow(pair)) }
        } else {
            body = "Couldn’t read this Mac’s Bluetooth devices. Press Refresh to try again."
        }
        var extras: [(title: String, action: () -> Void)] = [("Refresh", { [weak self] in self?.refreshSurvey() })]
        if survey?.pairs.isEmpty != false { extras.append(("Open Bluetooth Settings", { openSettingsURL(bluetoothSettingsURL) })) }
        return Page(symbol: symbolName("airpods.gen4", "airpods"), title: "Choose your AirPods", body: body, content: list, primary: "Continue",
                    primaryEnabled: SetupFlow.canContinue(.airpods, permissions: permissions, hasAirPods: selected != nil),
                    primaryAction: { [weak self] in
                        guard let self else { return }
                        if let selected { try? ClosedCaseAirPods.save(selected) }
                        go(to: .connect)
                    }, extras: extras)
    }

    private func connectPage() -> Page {
        let status = supervisor.status
        var page = Page(symbol: symbolName("antenna.radiowaves.left.and.right", "dot.radiowaves.left.and.right"), title: "Connect your case", body: "")
        if let failure = failureText(status) {
            page.body = failure
            page.primary = "Try again"
            page.primaryAction = { [weak self] in self?.supervisor.start() }
            if status == .crashLoop { page.extras = [("Open Logs Folder", { NSWorkspace.shared.open(logsFolder) })] }
            return page
        }
        let raw = supervisor.state.session
        let chip = StatusChip()
        chip.set(SessionText.session(raw), live: false)
        switch raw {
        case _ where SessionText.waitsForLid(raw): page.body = "Open the case lid, then close it again."
        case "ready: close the lid", "lid closed", "streaming": page.body = "Hold the case still in your right hand. Calibration starts next."
        default: page.body = "Put both earbuds in the case, close the lid and hold it in your right hand."
        }
        page.content = centered(chip)
        page.primary = "Connecting…"
        page.primaryEnabled = false
        return page
    }

    private func calibratePage() -> Page {
        var page = Page(symbol: symbolName("gyroscope", "dot.viewfinder"), title: "Calibrate", body: "Follow the instruction below and keep holding the case the way you’ll play.")
        if let failure = failureText(supervisor.status) {
            page.body = failure
            page.primary = "Try again"
            page.primaryAction = { [weak self] in self?.go(to: .connect) }
            return page
        }
        let stack = rkVStack(spacing: 14, align: .centerX)
        if let prompt = flow.prompt {
            if let n = SetupFlow.calibrationNumber(prompt) {
                let chip = StatusChip()
                chip.set("Step \(n) of \(SetupFlow.calibrationSteps)", dot: false)
                stack.addArrangedSubview(chip)
            }
            let text = rkTitle(prompt, 22, align: .center)
            stack.addArrangedSubview(text)
            text.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else {
            stack.addArrangedSubview(rkLabel("Waiting for the first instruction…", 15, .regular, .secondaryLabelColor))
        }
        page.content = stack
        page.extras = [("Recalibrate", { [weak self] in self?.supervisor.send(.recalibrate) })]
        return page
    }

    private func gesturesPage() -> Page {
        let tiles: [(GestureTile, String, String, String)] = [
            (.jerkDown, symbolName("arrow.down.to.line", "arrow.down.circle"), "Jerk down", "Left click"),
            (.shake, symbolName("arrow.up.arrow.down", "hand.draw"), "Shake", "Hold left button"),
            (.jerkUp, symbolName("arrow.up.to.line", "arrow.up.circle"), "Jerk up", "Right click"),
            (.pull, symbolName("arrow.down.backward.circle", "arrow.down.circle"), "Pull toward you", "Hold right button"),
            (.twist, symbolName("rotate.right", "arrow.clockwise"), "Twist", "Next or previous slot"),
            (.pause, symbolName("pause.circle", "pause.fill"), "Lay it flat and still", "Pause"),
        ]
        func tileView(_ t: (GestureTile, String, String, String)) -> NSView {
            let lit = flow.lit.contains(t.0)
            let surface = RemoteSurface(lit ? HomePalette.ink : HomePalette.raised, radius: 12)
            let text = lit ? HomePalette.canvas : NSColor.labelColor, caption = lit ? HomePalette.canvas.withAlphaComponent(0.8) : NSColor.secondaryLabelColor
            let title = rkWrap(t.2, 13, text, .semibold, align: .center), sub = rkWrap(t.3, 12, caption, align: .center)
            let stack = rkVStack([rkSymbolView(t.1, 24, text, .regular), title, sub], spacing: 4, align: .centerX)
            rkPin(stack, in: surface, insets: NSEdgeInsets(top: 14, left: 8, bottom: 14, right: 8))
            for label in [title, sub] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            surface.setAccessibilityLabel("\(t.2): \(t.3)\(lit ? ", done" : "")")
            return surface
        }
        func gridRow(_ items: ArraySlice<(GestureTile, String, String, String)>) -> NSStackView {
            let row = rkHStack(items.map(tileView), spacing: 10)
            row.distribution = .fillEqually
            return row
        }
        let grid = rkVStack([gridRow(tiles[0..<3]), gridRow(tiles[3..<6])], spacing: 10, align: .leading)
        for row in grid.arrangedSubviews { row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true }
        var content = [grid as NSView]
        if uptimeNow() < vetoHintUntil { content.append(rkWrap("Make a short calm pause before the gesture.", 13, .secondaryLabelColor, align: .center)) }
        let stack = rkVStack(content, spacing: 14, align: .centerX)
        for view in content { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        var page = Page(symbol: symbolName("hand.tap", "hand.point.up"), title: "Try the gestures",
                        body: "Each tile lights up when MinePointer feels the gesture. Nothing is clicked in this window.",
                        content: stack, primary: "Done", primaryAction: next())
        if let failure = failureText(supervisor.status) { page.body = failure }
        page.extras = [("Skip", next())]
        return page
    }

    private func donePage() -> Page {
        let tips = rkVStack([
            row(symbolName("computermouse", "cursorarrow"), "Set Minecraft’s mouse sensitivity to 60%, or adjust it in Settings."),
            row(symbolName("rectangle.expand.vertical", "arrow.up.left.and.arrow.down.right"), "Play fullscreen."),
            row(symbolName("keyboard.badge.ellipsis", "keyboard"), "Close keyboard-layout switchers that use event taps (Keyboop, for example) while you play. They can leave movement keys stuck."),
            row(symbolName("clock", "timer"), "The AirPods end the stream after about 30 minutes. Open and close the case lid to continue."),
            row(symbolName("exclamationmark.octagon", "exclamationmark.triangle"), "⌃⌥Space turns output off and on at any time. ⌃⌥C recalibrates."),
        ], spacing: 10, align: .leading)
        return Page(symbol: symbolName("checkmark.circle"), title: "You’re ready", body: "A few things worth knowing before you play.",
                    content: tips, primary: "Start playing", primaryAction: { [weak self] in self?.finish() },
                    extras: [("Open Settings", { [weak self] in self?.app.showSettings() })])
    }

    private func finish() {
        finished = true
        UserDefaults.standard.set(true, forKey: setupCompleteKey)
        supervisor.holdOutputOff = false
        if supervisor.status == .running { supervisor.send(.outputOn) } else { supervisor.start() }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate(); poll = nil
        attempt += 1; awaitingEngine = false
        supervisor.holdOutputOff = false
        if !finished, supervisor.status == .running { supervisor.send(.outputOn) }
        AccessibilityGuide.shared.stop()
    }

    // MARK: pieces

    private func failureText(_ status: EngineStatus) -> String? {
        switch status {
        case .failed(let text): return text
        case .crashLoop: return "The engine keeps crashing. The log is at \(EngineSupervisor.logURL.path)."
        case .stopped, .running: return nil
        }
    }

    private func centered(_ view: NSView) -> NSView {
        let holder = rkVStack([view], spacing: 0, align: .centerX)
        return holder
    }

    private func row(_ symbol: String, _ text: String) -> NSView {
        let label = rkWrap(text, 13, .labelColor)
        let stack = rkHStack([icon(symbol, 16, .secondaryLabelColor), label], spacing: 12)
        stack.alignment = .top
        return stack
    }

    /// A symbol in a fixed-width column, so the texts beside a list of icons line up.
    private func icon(_ symbol: String, _ size: CGFloat, _ color: NSColor) -> NSView {
        let view = rkSymbolView(symbol, size, color)
        view.imageAlignment = .alignCenter
        view.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return view
    }

    private func surfaceRow(_ views: [NSView]) -> NSView {
        let surface = RemoteSurface(HomePalette.raised, radius: 10)
        let stack = rkHStack(views, spacing: 12)
        rkPin(stack, in: surface, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
        return surface
    }

    private func permissionRow(_ symbol: String, _ title: String, _ caption: String, _ granted: Bool, _ buttonTitle: String, _ action: @escaping () -> Void) -> NSView {
        let words = rkVStack([rkLabel(title, 13, .semibold), rkWrap(caption, 12)], spacing: 2, align: .leading)
        let trailing: NSView
        if granted {
            let chip = StatusChip(); chip.set("Allowed", dot: false); trailing = chip
        } else {
            trailing = actions.bind(RemoteButton(buttonTitle, style: .secondary, height: 32)) { _ in action() }
        }
        let row = surfaceRow([icon(symbol, 18, .labelColor), words, rkSpacer(), trailing])
        row.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return row
    }

    private func airPodsRow(_ pair: ClosedCaseAirPods) -> NSView {
        let supported = !pair.usesHeadphoneMotion
        let caption = supported ? (pair.connected ? "Connected" : "Not connected right now") : "AirPods Pro (1st generation) aren’t supported."
        let words = rkVStack([rkLabel(pair.title, 13, .semibold), rkWrap(caption, 12)], spacing: 2, align: .leading)
        let trailing: NSView
        if !supported {
            let chip = StatusChip(); chip.set("Not supported", dot: false); trailing = chip
        } else if selected == pair {
            let chip = StatusChip(); chip.set("Selected", dot: false); trailing = chip
        } else {
            trailing = actions.bind(RemoteButton("Use these", style: .secondary, height: 32)) { [weak self] _ in
                guard let self else { return }
                try? ClosedCaseAirPods.save(pair)
                selected = pair
                render()
            }
        }
        let row = surfaceRow([icon(symbolName("airpods.gen4", "airpods"), 18, .labelColor), words, rkSpacer(), trailing])
        row.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return row
    }
}
