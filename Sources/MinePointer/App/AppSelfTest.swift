import Foundation

/// Offline checks of the UI's pure logic: restart policy, slider mappings, session texts, setup flow, menu icon, app icon.
func appSelfTest() {
    // Restart policy: a requested stop does nothing, an @error is shown, anything else restarts up to 3 times in 120 s.
    precondition(engineExitAction(requested: true, error: nil, restarts: [], now: 10) == .none)
    precondition(engineExitAction(requested: true, error: "x", restarts: [], now: 10) == .none, "a requested stop wins over a late error")
    precondition(engineExitAction(requested: false, error: "no AirPods", restarts: [], now: 10) == .failed("no AirPods"))
    precondition(engineExitAction(requested: false, error: nil, restarts: [], now: 10) == .restart)
    precondition(engineExitAction(requested: false, error: nil, restarts: [1, 2], now: 10) == .restart)
    precondition(engineExitAction(requested: false, error: nil, restarts: [1, 2, 3], now: 10) == .crashLoop)
    precondition(engineExitAction(requested: false, error: nil, restarts: [1, 2, 3], now: 122) == .restart, "restarts older than 120 s do not count")
    precondition(engineExitAction(requested: false, error: nil, restarts: [1, 50, 100], now: 120.5) == .crashLoop)
    precondition(engineExitAction(requested: false, error: "x", restarts: [1, 2, 3], now: 10) == .failed("x"), "an error never loops")

    // Sliders: shown value ↔ config value, snapped and clamped; every default sits on its slider.
    let sensitivity = SliderSetting.camera[0]
    precondition(sensitivity.shown(fromConfig: 0.3) == 60 && sensitivity.config(fromShown: 60) == 0.3)
    precondition(sensitivity.config(fromShown: 200) == 1 && sensitivity.config(fromShown: 250) == 1 && sensitivity.config(fromShown: -5) == 0)
    precondition(sensitivity.text(60) == "60%")
    let gain = SliderSetting.camera[1]
    precondition(gain.config(fromShown: 3.04) == 3.0 && gain.config(fromShown: 9) == 6 && gain.text(3) == "3.0×")
    for setting in SliderSetting.all {
        let value = Config()[keyPath: setting.path]
        precondition(value >= setting.lower / setting.scale - 1e-9 && value <= setting.upper / setting.scale + 1e-9, "\(setting.key) default is off its slider")
        precondition(abs(setting.config(fromShown: setting.defaultShown) - value) < 1e-6, "\(setting.key) default does not round-trip")
    }
    let defaults = settingsDefaults()
    precondition(defaults["neutral_up"] == nil && defaults["forward_axis"] == nil, "reset must keep the calibration")
    precondition(defaults["mc_sensitivity"] as? Double == 0.3 && defaults["scroll_next_sign"] as? Int == -1 && defaults["record_sessions"] as? Bool == false)

    // Session and mode texts.
    precondition(SessionText.session("waiting: open the case lid") == "Open and close the case lid")
    precondition(SessionText.session("streaming") == "Connected" && SessionText.session("") == "Starting…")
    precondition(SessionText.session("AirPods busy, retry 2 of 5") == "AirPods busy, trying again (2)")
    precondition(SessionText.session("session ended: stream lost") == "Session ended (stream lost)")
    precondition(SessionText.session("AirPods are in use elsewhere") == "AirPods are in use elsewhere", "unknown text passes through")
    precondition(SessionText.mode("output off") == "Output off" && SessionText.mode("") == "")
    precondition(SessionText.line(EngineState(session: "streaming", mode: "")) == "Connected")
    precondition(SessionText.line(EngineState(session: "streaming", mode: "paused")) == "Paused (case flat)")
    precondition(SessionText.line(EngineState(session: "connecting", mode: "reconnecting")) == "Reconnecting · Connecting to your AirPods")

    // Menu icon and status row.
    precondition(MenuIcon.of(.stopped, EngineState()) == .stopped && MenuIcon.of(.crashLoop, EngineState()) == .error)
    precondition(MenuIcon.of(.failed("x"), EngineState()) == .error)
    precondition(MenuIcon.of(.running, EngineState(session: "streaming")) == .running)
    precondition(MenuIcon.of(.running, EngineState(session: "streaming", mode: "paused")) == .attention)
    precondition(MenuIcon.of(.running, EngineState(session: "waiting: open the case lid")) == .attention)
    precondition(menuStatusText(.stopped, EngineState()) == "Stopped" && menuStatusText(.crashLoop, EngineState()) == "The engine keeps crashing")
    precondition(menuStatusText(.failed(String(repeating: "a", count: 100)), EngineState()).count < 90)

    // Setup flow.
    var flow = SetupFlow()
    precondition(SetupStep(rawValue: 4) == .connect && SetupFlow.back(from: .permissions) == .welcome && SetupFlow.back(from: .calibrate) == nil)
    flow.step = .connect
    flow.apply(.state(EngineState(session: "connecting")))
    precondition(flow.step == .connect)
    flow.apply(.state(EngineState(session: "waiting: open the case lid", mode: "calibrating")))
    precondition(flow.step == .connect, "the engine calibrates from its start: only a prompt leaves the connect step")
    flow = SetupFlow(); flow.step = .connect
    flow.apply(.prompt("Calibration: hold the case still in your usual grip…"))
    precondition(flow.step == .calibrate && flow.prompt != nil)
    precondition(SetupFlow.calibrationNumber("Calibration: hold the case still in your usual grip…") == 1)
    precondition(SetupFlow.calibrationNumber("Make 3 clockwise twists (and back), with a short pause between them") == 2)
    precondition(SetupFlow.calibrationNumber("Slowly raise and lower the far end of the case twice") == 3 && SetupFlow.calibrationNumber("x") == nil)
    precondition(SetupFlow.calibrationClip(2)?.id == "calibration-twists" && SetupFlow.calibrationClip(4) == nil)
    precondition(SetupFlow.caseArt(session: "waiting: open the case lid", mode: "calibrating", prompt: nil)?.id == "lid-open")
    precondition(SetupFlow.caseArt(session: "ready: close the lid", mode: "calibrating", prompt: nil)?.id == "lid-close")
    precondition(SetupFlow.caseArt(session: "streaming", mode: "calibrating", prompt: "Make 3 clockwise twists (and back), with a short pause between them")?.id == "calibration-twists")
    precondition(SetupFlow.caseArt(session: "connecting", mode: "reconnecting", prompt: nil)?.id == "connect")
    precondition(SetupFlow.caseArt(session: "streaming", mode: "", prompt: nil) == nil)
    var demo = SetupFlow()
    precondition(demo.demoTile == .jerkDown)
    demo.lit = [.jerkDown]
    precondition(demo.demoTile == .shake, "the demo moves on to the first tile not lit yet")
    demo.lit = Set(GestureTile.allCases)
    precondition(demo.demoTile == .jerkDown)
    demo.picked = .pause
    precondition(demo.demoTile == .pause, "a clicked tile wins")
    let holds = EngineSupervisor()          // never started: the commands go nowhere, the hold bookkeeping is what is checked
    holds.holdOutput("setup"); holds.holdOutput("sandbox"); holds.holdOutput("sandbox")
    holds.releaseOutput("sandbox")
    precondition(holds.holdsOutput, "closing the sandbox must not release setup's hold")
    holds.releaseOutput("setup", turnOn: true)
    precondition(!holds.holdsOutput)
    flow.apply(.gesture(.jerkDown))
    precondition(flow.lit.isEmpty, "gestures count on the gesture step only")
    flow.apply(.calibrated)
    precondition(flow.step == .gestures && flow.calibrated && flow.prompt == nil)
    flow.apply(.gesture(.bowShot)); flow.apply(.gesture(.twistPrevious)); flow.apply(.gesture(.resume))
    precondition(flow.lit == [.jerkUp, .twist], "bowShot lights jerk up, either twist lights twist, resume lights nothing")
    flow.apply(.gesture(.veto))
    precondition(flow.vetoes == 1 && flow.lit.count == 2)
    precondition(Set(EngineGesture.allCases.compactMap(GestureTile.init)) == Set(GestureTile.allCases), "every tile can light")
    var permissions = SetupPermissions(bluetooth: true, accessibility: false, inputMonitoring: true)
    precondition(!SetupFlow.canContinue(.permissions, permissions: permissions, hasAirPods: false))
    permissions.accessibility = true; permissions.inputMonitoring = false
    precondition(SetupFlow.canContinue(.permissions, permissions: permissions, hasAirPods: false), "Input Monitoring is not required")
    precondition(!SetupFlow.canContinue(.airpods, permissions: permissions, hasAirPods: false) && SetupFlow.canContinue(.airpods, permissions: permissions, hasAirPods: true))
    // Main window guidance.
    precondition(homeGuidance(.stopped, EngineState(), prompt: "").hasPrefix("Stopped"))
    precondition(homeGuidance(.running, EngineState(session: "waiting: open the case lid", mode: "calibrating"), prompt: "") == "Open the case lid, then close it again.",
                 "the lid wait wins over the calibrating mode")
    precondition(homeGuidance(.running, EngineState(session: "streaming", mode: "calibrating"), prompt: "Make 3 twists") == "Make 3 twists")
    precondition(homeGuidance(.running, EngineState(session: "streaming"), prompt: "").hasPrefix("Ready"))
    precondition(homeGuidance(.failed("No AirPods"), EngineState(), prompt: "") == "No AirPods")
    // App icon: an unknown or missing config value falls back to the bundle's own icon; a built bundle carries every icon.
    precondition(AppIconChoice.from("graphite") == .graphite && AppIconChoice.from(nil) == .green && AppIconChoice.from("x") == .green)
    precondition(settingsDefaults()[AppIconChoice.configKey] as? String == AppIconChoice.green.rawValue, "reset restores the default icon")
    if Bundle.main.bundleURL.pathExtension == "app" {
        for name in AppIconChoice.allCases.map({ "AppIcon-\($0.rawValue)" }) + ["AppIcon"] {
            precondition(Bundle.main.url(forResource: name, withExtension: "icns") != nil, "\(name).icns missing from the bundle")
        }
        precondition(Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg") != nil, "MenuBarIcon.svg missing from the bundle")
    }
    print("PASS: app restart policy, settings mappings, session texts, setup flow, home guidance, app icon")
}
