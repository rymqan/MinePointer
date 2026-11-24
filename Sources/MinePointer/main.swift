import AppKit
import Carbon.HIToolbox

// Modes: --self-test (offline checks), --replay [take ...] (recordings through the camera), --calibrate-log <helper.txt> (wizard steps 1-2 on a recording), otherwise live.
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--self-test" {
    typesSelfTest()
    caseSessionSelfTest()
    cameraSelfTest()
    gestureSelfTest()
    calibrationSelfTest()
    indicatorSelfTest()
    engineLinkSelfTest()
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
if arguments.first == "--indicator" { runIndicator() }     // the panel child, started by the live app
if arguments.first == "--replay" {
    runReplay(arguments: Array(arguments.dropFirst()))
    exit(0)
}

// MARK: live

Config.writeDefaultsIfMissing()
let camera = Camera(config: Config.load())
let detector = GestureDetector(config: camera.config)
let output = MouseOutput()
let session = CaseSession()
var outputEnabled = true
var lastSampleArrival = 0.0
var lastLateNote = 0.0
var streamLost = false
var paused = false                  // case flat and still (detector .pause until .resume); for the indicator
var reconnecting = false            // the session dropped and is coming back; for the indicator
var lastGesture = "", gestureSeq = 0
func showGesture(_ text: String) { lastGesture = text; gestureSeq += 1 }
var calibration: Calibration?       // non-nil while the wizard runs: camera output and gesture events are dropped

func log(_ text: String) {
    let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(t)] \(text)")
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
            case .jerkDown: log("gesture: jerk down → LMB click"); showGesture("LMB click")
            case .shake: log("gesture: shake → LMB held"); showGesture("shake")
            case .shakeEnd: log("gesture: shake ended → LMB released")
            case .jerkUp: log("gesture: jerk up → RMB click"); showGesture("RMB click")
            case .pull: showGesture("pull"); log(output.rightDown ? "gesture: pull, RMB already held → no action" : "gesture: pull → RMB held")
            case .bowShot: log("gesture: jerk up with RMB held → shot, RMB released"); showGesture("shot")
            case .twist: break      // logged with its direction on the scroll action
            case .veto: showGesture("vetoed"); log("gesture: sharp motion without a calm pause before it → vetoed, the camera did not move")
            }
        case .action(.pause):
            paused = true
            output.releaseAll()     // the detector already dropped its own state; the camera stays masked until .resume
            log("paused: the case lies still → all buttons released, camera off")
        case .action(.resume):
            paused = false
            camera.unmask(keepBand: false)      // the pick-up is not aim: nothing queued during the pause reaches the game
            log("resumed: the case is in hand → gestures and camera work again")
        case .action(let action):
            guard outputEnabled else { continue }
            switch action {
            case .lmbDown: output.button(left: true, down: true)
            case .lmbUp: output.button(left: true, down: false)
            case .rmbDown: output.button(left: false, down: true)
            case .rmbUp: output.button(left: false, down: false)
            case .scroll(let dir):      // dir +1 = clockwise twist = "next slot"; the one place where the wheel sign is applied
                let wheel = Int32(dir * camera.config.scrollNextSign)
                output.scroll(wheel)
                showGesture(dir > 0 ? "slot +1" : "slot −1")
                log("gesture: twist \(dir > 0 ? "clockwise" : "counterclockwise") → wheel \(wheel)")
            case .pause, .resume: break
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
}

let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
log("Accessibility: \(trusted ? "granted" : "NOT granted — allow it in Privacy & Security → Accessibility and restart")")

session.onState = { log("session: \($0)") }
session.onSample = { sample in
    lastSampleArrival = uptimeNow()
    retriedNow = false
    reconnecting = false
    everStreamed = true
    let late = lastSampleArrival - sample.receivedUptime          // trace only: helper stamp → our read, for the choppy-camera stalls
    if late > 0.04, lastSampleArrival - lastLateNote > 0.02 { output.note("sample_late", ms: late * 1000); lastLateNote = lastSampleArrival }
    if streamLost { streamLost = false; log("stream restored") }
    let frame = camera.feed(sample)
    if let wizard = calibration {
        for prompt in wizard.feed(sample) { log(prompt) }
        if let axes = wizard.axes { finishCalibration(axes) }
        return
    }
    if let frame { apply(detector.feed(frame, now: uptimeNow())) }
}
// A dropped stream reconnects by itself (buttons released, camera without input meanwhile; same calibration after).
var retriedNow = false      // one immediate retry per drop; reset by the first sample of a working stream
var everStreamed = false
session.onEnded = { status, requested in
    abortGestures()
    let code = status.map(String.init) ?? "none"
    switch reconnectAction(status: status, requested: requested, streamed: everStreamed) {
    case .exit:
        log("session ended, helper exit code \(code). Quitting.")
        exit(0)
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

// Panic hotkey ⌃⌥Space: release everything and stop output; press again to resume.
let panicKey = HotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey) {
    outputEnabled.toggle()
    abortGestures()
    log(outputEnabled ? "output ON" : "output OFF (panic key): all buttons released")
}
if panicKey == nil { log("WARNING: could not register the panic key ⌃⌥Space") }

// Calibration hotkey ⌃⌥C: run the wizard again (a different grip).
let calibrationKey = HotKey(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey) { startCalibration() }
if calibrationKey == nil { log("WARNING: could not register the calibration key ⌃⌥C") }

let watcher = ConfigWatcher { config in
    camera.config = config
    detector.config = config
    log("settings reloaded")
}

signal(SIGPIPE, SIG_IGN)            // a dead indicator child must not kill MinePointer through its pipe
let indicator = camera.config.indicator ? Indicator() : nil
func indicatorState() -> IndicatorState {
    var s = IndicatorState()
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
outputTimer.setEventHandler {
    let now = uptimeNow()
    if lastTickAt > 0, now - lastTickAt > 0.02 { output.note("tick_gap", ms: (now - lastTickAt) * 1000) }   // trace only: main thread stalls
    lastTickAt = now
    let (dx, dy) = camera.tick(now: now)
    if outputEnabled { output.move(dx: dx, dy: dy) }
    if calibration == nil { apply(detector.tick(now: now)) }
    indicator?.send(indicatorState())
    if lastSampleArrival > 0, !streamLost, now - lastSampleArrival > camera.config.streamLossMs / 1000 {
        streamLost = true
        abortGestures()
        log("stream lost: no data for \(Int(camera.config.streamLossMs)) ms, all buttons released")
    }
}
outputTimer.resume()

// Ctrl-C / kill: release buttons, let the helper clean up, quit.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        output.releaseAll()
        log("stopping…")
        session.shutdown()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

log("MinePointer: grip calibration starts once the stream runs. Panic key: ⌃⌥Space, recalibrate: ⌃⌥C. Settings: \(configURL.path)")
startCalibration()
session.start()
// A plain run loop, not NSApplication: macOS wakes a registered background app only every ~100 ms while a fullscreen game
// is frontmost (all threads, real-time included), which made the camera choppy. As a plain process it keeps 240 Hz.
CFRunLoopRun()
