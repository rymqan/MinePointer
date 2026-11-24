import Foundation

/// Where config.json and the logs live: under MINEPOINTER_DIR when set (the developer workflow: replay, tools/record.py),
/// otherwise in the user's Library folders.
func dataLocations(environment: [String: String], home: URL) -> (config: URL, logs: URL) {
    if let dir = environment["MINEPOINTER_DIR"], !dir.isEmpty {
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        return (root.appendingPathComponent("config.json"), root.appendingPathComponent("logs", isDirectory: true))
    }
    return (home.appendingPathComponent("Library/Application Support/MinePointer/config.json"),
            home.appendingPathComponent("Library/Logs/MinePointer", isDirectory: true))
}
private let locations = dataLocations(environment: ProcessInfo.processInfo.environment, home: URL(fileURLWithPath: NSHomeDirectory()))
let logsFolder = locations.logs
let configURL = locations.config

func uptimeNow() -> Double { ProcessInfo.processInfo.systemUptime }

/// One accelerometer (g) or gyroscope (deg/s) reading from AirPointer's helper.
struct MotionSample: Equatable {
    enum Kind: Int { case accel = 11, gyro = 12 }
    let kind: Kind
    let sensorTime: Double      // s, earbud clock
    let receivedUptime: Double  // s, Mac systemUptime when the row was written
    let x: Double, y: Double, z: Double

    /// Helper row: seq,service,sensor_us,received_uptime,x,y,z (raw values are unit × 1e5). Other lines → nil.
    init?(helperLine line: Substring) {
        let p = line.split(separator: ",", omittingEmptySubsequences: false)
        guard p.count == 7, let svc = Int(p[1]), let kind = Kind(rawValue: svc),
              let us = Double(p[2]), let recv = Double(p[3]),
              let x = Double(p[4]), let y = Double(p[5]), let z = Double(p[6]) else { return nil }
        self.init(kind: kind, sensorTime: us / 1e6, receivedUptime: recv, x: x / 1e5, y: y / 1e5, z: z / 1e5)
    }

    init(kind: Kind, sensorTime: Double, receivedUptime: Double, x: Double, y: Double, z: Double) {
        self.kind = kind; self.sensorTime = sensorTime; self.receivedUptime = receivedUptime
        self.x = x; self.y = y; self.z = z
    }

    var vector: SIMD3<Double> { SIMD3(x, y, z) }
}

/// Every tunable. Missing keys in config.json fall back to these defaults.
struct Config: Codable, Equatable {
    var mcSensitivity = 0.3            // Minecraft slider 60% = 0.3 (0–200% maps to 0–1)
    var gain = 3.0                     // camera degrees per degree of case rotation
    var invertY = false
    var deadzoneDps = 5.0              // below this the rate is scaled down quadratically
    var oneEuroMinCutoff = 1.0         // Hz
    var oneEuroBeta = 0.01             // per deg/s
    var jitterMs = 60.0                // output delay that turns bursty arrival into smooth motion
    var streamLossMs = 1000.0          // no samples this long → release everything
    var forwardAxis = [-0.42, -0.26, 0.87]  // "toward the screen" in sensor frame (twist axis); the calibration measures it
    var biasStillDps = 3.0             // gyro bias is learned only while |ω| stays below this
    var biasStillSeconds = 1.0         // ... for at least this long

    // Gestures. Accelerations are linear acceleration in g, gravity removed (in the world frame); "down" is along -neutral_up, the case-fixed up axis (a jerk is a wrist flick, the case moves along its own axis whatever the tilt); pull's forward component stays horizontal (world).
    var jerkOnsetG = 0.7               // downward acceleration that starts a jerk (aim_fast never exceeds 0.77 g in any direction)
    var gestureReturnMs = 1500.0       // how long the backlash band lasts after a gesture: returning the case after a gesture does not move the aim
    var rollbackMaxMs = 400.0          // on a press, the aim is rolled back over at most this much camera output (the wind-up since calm)
    var maskCandidateG = 0.4           // the camera is masked from this level, before the jerk is certain (aim_fast: see replay)
    var candidateMs = 150.0            // a candidate that has not reached jerk_onset_g by then is dropped, the camera resumes
    var jerkMaxOnsetG = 1.5            // a first frame above this is a violent bump (free_play 12 g), not a jerk ramp
    var jerkDirectionRatio = 0.8       // down (along the case axis) must be at least this share of |a_lin|: a jerk is mostly along it. It is also the share from which a toward-yourself motion is a jerk up, not a pull
    var jerkWindupMaxG = 1.3           // an upward wind-up (along the case axis) stronger than this before the jerk disqualifies it. Case axis, all takes: 1.0 to 2.5 give the same counts, 0.8 loses 2 jerk downs (live_1200); 1.3 kept (was 1.0 against the world vertical: looking down, the lift before a jerk down reached 1.05-1.24 g in live_1104)
    var jerkUpOnsetG = 0.85            // upward acceleration (along the case axis) that starts a jerk up (RMB click, or the bow shot while latched). jerk_up take: 30 of 30 at 0.85, 29 at 1.0, 22 at 1.2. jerk_shake keeps one wind-up RMB (61.64 s, the lift before the next rep, 0.95 share) at every level
    var jerkUpDirectionRatio = 0.8     // the same for a jerk up
    var jerkUpWindupMaxG = 1.0         // the mirror of jerk_windup_max_g: a downward wind-up stronger than this disqualifies a jerk up
    var onsetWindowMs = 250.0          // a jerk reaches its onset level within this long after the case leaves calm
    var armCalmMs = 200.0              // calm this long before a jerk can start; no new jerk before that (refractory)
    var calmLinG = 0.3                 // calm: |a_lin| below this ...
    var calmDps = 40.0                 // ... and |ω| below this
    var settleMs = 120.0               // calm this long ends a gesture: the camera resumes
    var maskTimeoutMs = 400.0          // the camera resumes at the latest this long after a gesture, calm or not (the backlash band absorbs the rest)
    var maskReleaseDps = 140.0         // a gesture's camera mask ends once |omega| has been below this for mask_rot_calm_ms (and not before mask_min_ms) ... Not calm_dps (40, it arms the gestures and still ends a veto's mask): the wrist keeps turning at 40-140 dps for hundreds of ms after a jerk, and the backlash band and the recovery zone take that. Recorded takes (mask median, jerk_down / jerk_up / bow): 40 dps 649/684/594 ms, 80 dps 582/554/375, 120 dps 549/300/252, 140 dps 340/295/250 (the median of jerk_down reaches 350 ms at 130 dps), 200 dps 330/290/245 but one shake leaks 47° in 2.5 s; in-mask residual of jerk_up max 1.65° at 150 dps (limit 2°)
    var maskRotCalmMs = 40.0           // ... (the braking of the hand is translation, the aim does not wait for it; the phase goes on as the refractory) ...
    var maskMinMs = 60.0               // ... not earlier than this after the gesture onset (0 lets the next wind-up through: a bow at 97° net)
    var recoveryZoneDeg = 15.0         // for recovery_zone_ms after a gesture (or veto) mask, case motion within this many degrees of the pre-gesture pose is scaled by recovery_gain: the hand wobbles there at 40-60 dps (below calm_dps) and used to reach the aim at gain 3. Recorded takes: the pose stays within 13° (jerk_down), 13° (bow shot), 22° (jerk_up) of the pre-gesture pose for 90% of the gestures; live medians 12-14°
    var recoveryGain = 0.5             // aim gain inside the zone relative to normal (1 = no zone, 0 = the zone is absorbed fully). Recorded net aim change over 2.5 s, max over jerk_down / jerk_up / bow / pull: 0.33 → 4.4 / 6.4 / 5.9 / 3.8°, 0.5 → 6.1 / 7.6 / 8.1 / 4.8°, 0.6 → 7.1 / 8.7 / 9.8 / 5.5° (with a 1500 ms zone)
    var recoveryZoneMs = 1500.0        // the zone lasts this long after the mask (at most gesture_return_ms: the backlash band outlives it and goes on absorbing the hand's way back). The wrist's way back takes about 1 s: with 500 ms (gain 0.6) the recorded max net is 10 / 12 / 13 / 11°, with 1000 ms (gain 0.5) 6.5 / 12.3 / 7 / 7.5°. The band itself must stay long: gesture_return_ms 1000 gives 28° (jerk_up), 800 ms 59°, 500 ms 80°
    var gesturePreMs = 120.0           // camera output is dropped from this long before the gesture onset
    var clickHoldMs = 150.0            // a click holds LMB this long (real time) unless a shake follows. Must stay below Minecraft's creative break repeat (~250 ms, 5 ticks) or one jerk breaks two blocks; a shake then re-presses on its first stroke
    var shakeBrakeG = 1.0              // upward stroke that must follow the jerk ...
    var shakeStrokeG = 1.0             // ... and then a second downward stroke at least this strong makes it a shake
    var shakeJoinMs = 600.0            // the second stroke must come within this long after the onset (live_map_1031 has shakes at 500-550 ms; 400 loses them and saves 80 ms of mask)
    var shakeWindowMs = 150.0          // window of the shake energy (RMS of the vertical acceleration)
    var shakeRmsG = 0.8                // the shake continues while the energy is above this
    var shakeHangoverMs = 250.0        // ... and for this long after it falls below, so pauses between strokes do not release
    var neutralUp = [0.02, -0.94, -0.35]    // up direction (negated raw accel) with the case held neutrally; the calibration measures it. Also the case-fixed axis the jerk down/up, shake and veto shapes are measured along

    // Pull and twist. Pull uses the forward component of a_lin (a push toward the screen does nothing), twist the roll rate ω·forward (dps).
    var pullOnsetG = 0.7               // acceleration toward yourself that fires a pull (weakest recorded first lobe 0.79 g; the same level as jerk_onset_g)
    var pullDirectionRatio = 0.8       // |forward| must be at least this share of |a_lin|
    var pullReboundG = 0.2             // a forward (push-direction) lobe above this ...
    var pullReboundMs = 400.0          // ... within this long before the onset means the hand is braking or winding up, not pulling (the braking of a push looks like a pull)
    var pullBrakeMs = 350.0            // after a pull or jerk up the hand brakes for about this long; the mask timeout starts after it (measured: braking ends ~0.4 s after the onset)
    var pullMaxDps = 100.0             // a pull is translation: |ω| stays below this from calm exit to the onset (recorded pulls: up to 83 dps; the one aim_fast pitch flick that looked like a pull reached 125)
    var twistCandidateDps = 200.0      // the camera is masked when the roll rate passes this ...
    var twistRollRatio = 0.8           // ... and roll is at least this share of |ω|
    var twistPeakDps = 250.0           // the first lobe must reach this rate (recorded twists: 360-780 dps) ...
    var twistMinDeg = 35.0             // ... and this angle about forward (recorded: 48-86°); spiky hand shocks have 100s of dps but only a few degrees
    var twistReturnFraction = 0.5      // a twist is confirmed once the roll angle is back by this share of its peak. A put-down rolls the case ~85° and never comes back; a twist returns to ~0°
    var twistReturnMs = 450.0          // ... within this long after the angle peak (recorded: 260-380 ms)
    var twistChainMs = 1500.0          // after a confirmed twist the next twist (either direction) is accepted without the calm arming for this long; the return lobe is still never a twist
    var twistChainLinG = 0.6           // |a_lin| limit at the start of a chained twist (the first twist uses calm_lin_g)
    var scrollNextSign = -1            // wheel1 value sent for "next slot" (clockwise twist); UNVERIFIED for Minecraft 26.3, checked live
    var pauseTiltDeg = 65.0            // the up axis further than this from neutralUp counts as "flat" ... (was 50: looking down at a block, 55-65°, and holding still for 1 s paused everything; the pause counts of every take are the same up to 65, at 70 one put-down in free_play is missed)
    var pauseStillMs = 1000.0          // ... and calm this long pauses everything
    var resumeTiltDeg = 35.0           // pause ends when the up axis is within this of neutralUp ...
    var resumeMs = 300.0               // ... for this long
    var indicator = false              // the on-screen panel (held buttons, last gesture, mode), shown by the UI app; off by default
    var recordSessions = false         // keep the raw helper recording (logs/helper-*.txt and .meta) for replay; off by default, read at session start

    /// Mouse counts per camera degree, from Minecraft's formula deg/count = (0.6 s + 0.2)^3 · 1.2 (UNVERIFIED for 26.3).
    var countsPerDegree: Double { 1 / (pow(0.6 * mcSensitivity + 0.2, 3) * 1.2) }

    static func load(from url: URL = configURL) -> Config {
        let defaults = Config()
        guard let data = try? Data(contentsOf: url),
              let user = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return defaults }
        let enc = JSONEncoder(); enc.keyEncodingStrategy = .convertToSnakeCase
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        guard let base = try? JSONSerialization.jsonObject(with: enc.encode(defaults)) as? [String: Any] else { return defaults }
        let merged = base.merging(user) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let config = try? dec.decode(Config.self, from: mergedData) else {
            print("config.json: invalid values, using defaults")
            return defaults
        }
        return config
    }

    /// Writes the defaults so the user has a file to edit.
    static func writeDefaultsIfMissing(to url: URL = configURL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.keyEncodingStrategy = .convertToSnakeCase
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(Config()).write(to: url)
    }
}

func typesSelfTest() {
    let s = MotionSample(helperLine: "80989,11,245310775,155195.959665458,82481,14604,54960")!
    precondition(s.kind == .accel && abs(s.x - 0.82481) < 1e-9 && abs(s.sensorTime - 245.310775) < 1e-9)
    precondition(MotionSample(helperLine: "Earbud ModelName=x") == nil)
    precondition(MotionSample(helperLine: "1,16,0,0,1,2,3") == nil)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("minepointer-config-test.json")
    try? #"{"gain": 5, "invert_y": true}"#.data(using: .utf8)!.write(to: tmp)
    let c = Config.load(from: tmp)
    precondition(c.gain == 5 && c.invertY && c.jitterMs == 60)
    precondition(c.scrollNextSign == -1 && c.pullOnsetG == Config().pullOnsetG, "pull and twist keys must fall back to their defaults")
    precondition(c.recoveryGain == Config().recoveryGain && c.recoveryZoneDeg == Config().recoveryZoneDeg && c.recoveryZoneMs == Config().recoveryZoneMs && c.maskReleaseDps == Config().maskReleaseDps, "recovery and veto keys must fall back to their defaults")
    try? #"{"scroll_next_sign": 1, "twist_peak_dps": 300}"#.data(using: .utf8)!.write(to: tmp)
    let c2 = Config.load(from: tmp)
    precondition(c2.scrollNextSign == 1 && c2.twistPeakDps == 300 && c2.pauseStillMs == 1000, "pull and twist keys not read from config.json")
    precondition(abs(Config().countsPerDegree - 15.19) < 0.05)
    try? FileManager.default.removeItem(at: tmp)
    let home = URL(fileURLWithPath: "/Users/someone")
    let dev = dataLocations(environment: ["MINEPOINTER_DIR": "/work/mp"], home: home)
    precondition(dev.config.path == "/work/mp/config.json" && dev.logs.path == "/work/mp/logs", "MINEPOINTER_DIR selects the project folder")
    let installed = dataLocations(environment: [:], home: home)
    precondition(installed.config.path == "/Users/someone/Library/Application Support/MinePointer/config.json" && installed.logs.path == "/Users/someone/Library/Logs/MinePointer")
    precondition(dataLocations(environment: ["MINEPOINTER_DIR": ""], home: home).config == installed.config, "an empty MINEPOINTER_DIR is unset")
    precondition(!Config().recordSessions && !c2.recordSessions)
    print("PASS: types, helper row parsing, config merge, data locations")
}
