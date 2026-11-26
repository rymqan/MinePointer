import AppKit
import Carbon.HIToolbox

// Modes: --self-test (offline checks), --replay [take ...] (recordings through the camera), --render-gestures <folder> (README GIFs), --clip-poses (clips for the fake engine), --calibrate-log <helper.txt> (wizard steps 1-2 on a recording),
// --engine (live: the child process of the UI app, talks EngineLink on stdout/stdin), anything else the UI app.
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--self-test" {
    typesSelfTest()
    caseSessionSelfTest()
    cameraSelfTest()
    gestureSelfTest()
    calibrationSelfTest()
    caseMotionSelfTest()
    engineLinkSelfTest()
    appSelfTest()
    exit(0)
}
if arguments.first == "--calibrate-log", arguments.count > 1 {     // steps 1-2 of the wizard on a helper log
    let url = URL(fileURLWithPath: arguments[1])
    guard let axes = calibrateLog(url, onPrompt: { print(String(format: "sensor %.1f s: %@", $0, $1)) }) else { print("no axes"); exit(1) }
    let config = Config.load()
    func show(_ v: SIMD3<Double>) -> String { String(format: "(%.3f, %.3f, %.3f)", v.x, v.y, v.z) }
    let old = (up: SIMD3(config.neutralUp[0], config.neutralUp[1], config.neutralUp[2]), forward: SIMD3(config.forwardAxis[0], config.forwardAxis[1], config.forwardAxis[2]))
    print("up \(show(axes.up)) forward \(show(axes.forward)); off the config axes by \(String(format: "%.1f° / %.1f°", angleDegrees(axes.up, old.up), angleDegrees(axes.forward, old.forward)))")
    exit(0)
}
if arguments.first == "--render-gestures", arguments.count > 1 {     // the README animations of CaseMotion.swift's clips
    renderGestureGIFs(to: URL(fileURLWithPath: arguments[1]))
    exit(0)
}
if arguments.first == "--clip-poses" {     // the gesture clips for tools/fake-engine.py
    printClipPoses()
    exit(0)
}
if arguments.first == "--replay" {
    runReplay(arguments: Array(arguments.dropFirst()))
    exit(0)
}

if arguments.first != "--engine" { runApp() }       // no arguments, or whatever Finder or Xcode passes

// MARK: live

setvbuf(stdout, nil, _IOLBF, 0)     // stdout is the UI's pipe: every line goes out at once
signal(SIGPIPE, SIG_IGN)            // a dead UI must not kill the engine through its pipe; stdin EOF quits it cleanly
Config.writeDefaultsIfMissing()
let camera = Camera(config: Config.load())
let detector = GestureDetector(config: camera.config)
let output = MouseOutput()
let session = CaseSession()
var outputEnabled = !arguments.contains("--output-off")      // the UI restarts a crashed engine with the person's choice
var lastSampleArrival = 0.0
var lastLateNote = 0.0
var streamLost = false
var paused = false                  // case flat and still (detector .pause until .resume); for the UI
var reconnecting = false            // the session dropped and is coming back; for the UI
var sessionText = ""                // the latest CaseSession state; for the UI
var lastGesture = "", gestureSeq = 0
/// The panel text and the "@gesture" line of a recognized gesture; sent also while output is off (the UI's gesture check).
func showGesture(_ text: String, _ id: EngineGesture) { lastGesture = text; gestureSeq += 1; send(.gesture(id)) }
func send(_ message: EngineMessage) { writeLine(message.line, droppable: false) }

/// stdout is the UI's pipe, and the UI process is throttled while the game is in front (or may hang): lines go out on their own
/// queue, so a full pipe never stalls the 240 Hz main thread that also releases the buttons. Past `maxPendingLines` waiting,
/// new log lines are dropped; protocol lines never are (an @calibrated or @error has no second copy), and they are few.
let stdoutQueue = DispatchQueue(label: "minepointer.stdout")
let pendingLock = NSLock()
var pendingLines = 0
let maxPendingLines = 1000
func writeLine(_ line: String, droppable: Bool = true) {
    pendingLock.lock()
    let room = !droppable || pendingLines < maxPendingLines
    if room { pendingLines += 1 }
    pendingLock.unlock()
    guard room else { return }
    stdoutQueue.async {
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))      // fails (EPIPE) once the UI is gone
        pendingLock.lock(); pendingLines -= 1; pendingLock.unlock()
    }
}

/// Before exit: give the queued lines (an @error above all) up to a second to reach the UI.
func flushLines() {
    let done = DispatchSemaphore(value: 0)
    stdoutQueue.async { done.signal() }
    _ = done.wait(timeout: .now() + 1)
}
var calibration: Calibration?       // non-nil while the wizard runs: camera output and gesture events are dropped

func log(_ text: String) {
    let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    writeLine("[\(t)] \(text)")
}

/// Gesture detector → camera mask, mouse buttons and log. While the panic key has output off nothing is pressed.
func apply(_ events: [GestureEvent]) {
    for event in events {
        switch event {
        case .maskStart(let time): camera.mask(from: time)
        case .maskEnd: camera.unmask()
        case .rollback(let from):
            let back = camera.rollback(from: from)         // before the press, so the click lands where the aim was calm
            if outputEnabled { output.move(dx: back.dx, dy: back.dy) }
        case .recognized(let name):
            switch name {
            case .jerkDown: log("gesture: jerk down → LMB click"); showGesture("LMB click", .jerkDown)
            case .shake: log("gesture: shake → LMB held"); showGesture("shake", .shake)
            case .shakeEnd: log("gesture: shake ended → LMB released")
            case .jerkUp: log("gesture: jerk up → RMB click"); showGesture("RMB click", .jerkUp)
            case .pull: showGesture("pull", .pull); log(output.rightDown ? "gesture: pull, RMB already held → no action" : "gesture: pull → RMB held")
            case .bowShot: log("gesture: jerk up with RMB held → shot, RMB released"); showGesture("shot", .bowShot)
            case .twist: break      // logged and sent with its direction on the scroll action
            case .veto: showGesture("vetoed", .veto); log("gesture: sharp motion without a calm pause before it → vetoed, the camera did not move")
            }
        case .action(.pause):
            paused = true
            send(.gesture(.pause))
            output.releaseAll()     // the detector already dropped its own state; the camera stays masked until .resume
            log("paused: the case lies still → all buttons released, camera off")
        case .action(.resume):
            paused = false
            send(.gesture(.resume))
            camera.unmask(keepBand: false)      // the pick-up is not aim: nothing queued during the pause reaches the game
            log("resumed: the case is in hand → gestures and camera work again")
        case .action(.scroll(let dir)):     // dir +1 = clockwise twist = "next slot"; the one place where the wheel sign is applied
            showGesture(dir > 0 ? "slot +1" : "slot −1", dir > 0 ? .twistNext : .twistPrevious)
            let turn = dir > 0 ? "clockwise" : "counterclockwise"
            if outputEnabled {
                let wheel = Int32(dir * camera.config.scrollNextSign)
                output.scroll(wheel)
                log("gesture: twist \(turn) → wheel \(wheel)")
            } else {
                log("gesture: twist \(turn) → output off, no wheel")
            }
        case .action(let action):
            guard outputEnabled else { continue }
            switch action {
            case .lmbDown: output.button(left: true, down: true)
            case .lmbUp: output.button(left: true, down: false)
            case .rmbDown: output.button(left: false, down: true)
            case .rmbUp: output.button(left: false, down: false)
            case .scroll, .pause, .resume: break
            }
        }
    }
}

/// Forget gesture state and release the camera: stream loss and the panic key.
func abortGestures() {
    detector.reset()
    paused = false
    camera.unmask()
    if calibration != nil { camera.mask(from: 0) }      // the wizard keeps the camera quiet: the panic key and a lost stream must not release it
    output.releaseAll()
}

/// The wizard (at every start and on ⌃⌥C): buttons released, detector reset, camera masked from the very first sample.
/// The camera keeps being fed (it learns the gyro bias while the case is still); only its output is dropped.
func startCalibration() {
    calibration = Calibration()
    sentProgress = 0
    abortGestures()
}

func finishCalibration(_ axes: CalibrationAxes) {
    let old = SIMD3<Double>(camera.config.forwardAxis[0], camera.config.forwardAxis[1], camera.config.forwardAxis[2])
    let stored = Config.storeCalibration(axes)
    var config = camera.config
    config.neutralUp = stored.up
    config.forwardAxis = stored.forward
    camera.config = config
    detector.config = config
    calibration = nil
    detector.reset()
    camera.unmask(keepBand: false)      // nothing queued while calibrating reaches the game
    session.recordCalibration(up: stored.up, forward: stored.forward)
    log(String(format: "calibration done: the forward axis turned %.0f° from the previous one", angleDegrees(axes.forward, old)))
    send(.calibrated)
}

/// A fatal problem: the UI shows the text, the engine exits nonzero.
func fail(_ text: String) -> Never {
    send(.error(text))
    log(text)
    flushLines()
    exit(1)
}

// No prompt here: the UI asks for the permission, the engine only checks it.
guard AXIsProcessTrusted() else { fail(engineErrorTextAccessibility) }
log("Accessibility: granted")

var sentProgress = 0.0              // the last @progress of the calibration
var sendPose = false                // the UI's sandbox is open
var poseTracker = CasePoseTracker()
var lastPoseSent = 0.0
session.onState = { sessionText = $0; log("session: \($0)") }
session.onSample = { sample in
    lastSampleArrival = uptimeNow()
    retriedNow = false
    reconnecting = false
    everStreamed = true
    let late = lastSampleArrival - sample.receivedUptime          // trace only: helper stamp → our read, for the choppy-camera stalls
    if late > 0.04, lastSampleArrival - lastLateNote > 0.02 { output.note("sample_late", ms: late * 1000); lastLateNote = lastSampleArrival }
    if streamLost { streamLost = false; log("stream restored") }
    let frame = camera.feed(sample)
    if sendPose {
        poseTracker.feed(sample, config: camera.config)
        if sample.receivedUptime - lastPoseSent >= 1.0 / 30 {     // droppable: a lost pose is replaced by the next one
            lastPoseSent = sample.receivedUptime
            let q = poseTracker.rotation, p = poseTracker.position
            writeLine(EngineMessage.pose([p.x, p.y, p.z, q.imag.x, q.imag.y, q.imag.z, q.real]).line)
        }
    }
    if let wizard = calibration {
        for prompt in wizard.feed(sample) { log(prompt); send(.prompt(prompt)) }
        if abs(wizard.progress - sentProgress) >= 0.05 {          // droppable: the next one replaces it
            sentProgress = wizard.progress
            writeLine(EngineMessage.progress(sentProgress).line)
        }
        if let axes = wizard.axes { finishCalibration(axes) }
        return
    }
    if let frame { apply(detector.feed(frame, now: uptimeNow())) }
}
// A dropped stream reconnects by itself (buttons released, camera without input meanwhile; same calibration after).
var retriedNow = false      // one immediate retry per drop; reset by the first sample of a working stream
var everStreamed = false
session.onEnded = { status, requested, reason in
    abortGestures()
    let code = status.map(String.init) ?? "none"
    switch reconnectAction(status: status, requested: requested, streamed: everStreamed) {
    case .exit:
        log("session ended, helper exit code \(code). Quitting.")
        if requested { flushLines(); exit(0) }
        fail(engineErrorText(reason))
    case .retryNow where !retriedNow:
        retriedNow = true
        reconnecting = true
        log("stream dropped (code \(code)): reconnecting…")
        DispatchQueue.main.async { session.start() }
    case .retryNow, .waitForLid:
        reconnecting = true
        log(status == 43 ? "stream dropped (AirPods ~30 min limit): open and close the case lid — I will reconnect"
                         : "stream dropped (code \(code)): open and close the case lid — I will reconnect")
        DispatchQueue.main.async { session.start(waitForLid: true, lidTimeout: false) }
    }
}

/// The panic key's effect, also set explicitly by the UI's "output on" / "output off".
func setOutput(_ on: Bool) {
    guard on != outputEnabled else { return }
    outputEnabled = on
    abortGestures()
    log(outputEnabled ? "output ON" : "output OFF (panic key): all buttons released")
}

// Panic hotkey ⌃⌥Space: release everything and stop output; press again to resume.
let panicKey = HotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey) { setOutput(!outputEnabled) }
if panicKey == nil { log("WARNING: could not register the panic key ⌃⌥Space") }

// Calibration hotkey ⌃⌥C: run the wizard again (a different grip).
let calibrationKey = HotKey(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey) { startCalibration() }
if calibrationKey == nil { log("WARNING: could not register the calibration key ⌃⌥C") }

let watcher = ConfigWatcher { config in
    camera.config = config
    detector.config = config
    log("settings reloaded")
}

func engineState() -> EngineState {
    var s = EngineState()
    s.session = sessionText
    s.output = outputEnabled
    s.left = output.leftDown
    s.right = output.rightDown
    s.mode = calibration != nil ? "calibrating" : !outputEnabled ? "output off" : reconnecting ? "reconnecting"
        : streamLost ? "no stream" : paused ? "paused" : ""
    s.gesture = lastGesture
    s.seq = gestureSeq
    return s
}

// Output clock: 240 Hz on the main queue.
let outputTimer = DispatchSource.makeTimerSource(queue: .main)
outputTimer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 240), leeway: .microseconds(500))
var lastTickAt = 0.0
var lastSentState: EngineState?
outputTimer.setEventHandler {
    let now = uptimeNow()
    if lastTickAt > 0, now - lastTickAt > 0.02 { output.note("tick_gap", ms: (now - lastTickAt) * 1000) }   // trace only: main thread stalls
    lastTickAt = now
    let (dx, dy) = camera.tick(now: now)
    if outputEnabled { output.move(dx: dx, dy: dy) }
    if calibration == nil { apply(detector.tick(now: now)) }
    let state = engineState()
    if state != lastSentState { lastSentState = state; send(.state(state)) }
    if lastSampleArrival > 0, !streamLost, now - lastSampleArrival > camera.config.streamLossMs / 1000 {
        streamLost = true
        abortGestures()
        log("stream lost: no data for \(Int(camera.config.streamLossMs)) ms, all buttons released")
    }
}
outputTimer.resume()

// Ctrl-C / kill / the "quit" command / the UI's end of stdin: release buttons, let the helper clean up, quit.
func quit() -> Never {
    output.releaseAll()
    log("stopping…")
    session.shutdown()
    flushLines()
    exit(0)
}
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { quit() }
    src.resume()
    signalSources.append(src)
}

// Commands from the UI, one per line on stdin (a terminal works too). EOF means the UI is gone: quit, so no button stays held.
var commandSplitter = LineSplitter()
let commandSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
commandSource.setEventHandler {
    var bytes = [UInt8](repeating: 0, count: 4096)
    let count = read(STDIN_FILENO, &bytes, bytes.count)
    if count == 0 { log("stdin closed"); quit() }
    guard count > 0 else { return }
    for line in commandSplitter.feed(Data(bytes.prefix(count))) {
        switch EngineCommand(rawValue: line.trimmingCharacters(in: .whitespaces)) {
        case .recalibrate?: startCalibration()
        case .outputOn?: setOutput(true)
        case .outputOff?: setOutput(false)
        case .poseOn?: sendPose = true; poseTracker = CasePoseTracker()
        case .poseOff?: sendPose = false
        case .quit?: quit()
        case nil: log("unknown command: \(line)")
        }
    }
}
commandSource.resume()

log("MinePointer: grip calibration starts once the stream runs. Panic key: ⌃⌥Space, recalibrate: ⌃⌥C. Settings: \(configURL.path)")
startCalibration()
session.start()
// A plain run loop, not NSApplication: macOS wakes a registered background app only every ~100 ms while a fullscreen game
// is frontmost (all threads, real-time included), which made the camera choppy. As a plain process it keeps 240 Hz.
CFRunLoopRun()
