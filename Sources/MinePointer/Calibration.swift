import Foundation

// Calibration wizard: re-measures `neutral_up` and `forward_axis` in the grip the user holds the case in now.
// The symmetric case has no marked front, so the grip changes between sessions and a turned grip inverts the pitch and
// kills the twists (the axes live in the sensor frame). A pure state machine: fed MotionSamples (raw, as the helper writes
// them: the accelerometer reports gravity DOWN, the gyro is right-handed, deg/s), it returns the prompts to show
// and, at the end, the axes. Time is sensor time throughout, so bursty arrival does not matter.
//
// Steps (conventions of Camera.swift: right = forward × up, ω·right > 0 raises the far end, a clockwise twist has a
// POSITIVE first lobe about forward):
//  1. still ≥ 3 s: up = normalized negated mean accel over the still span.
//  2. 3 twists: the axis is the principal axis of ω over the bursts (sign-blind), the sign comes from the first lobes.
//     Twists alone cannot tell clockwise from counter-clockwise on a symmetric case, so a ccw set would store a flipped
//     forward (pitch inverted, twists dead).
//  3. raise and lower the far end: pitch rate p = ω·right must go positive first. This is an independent sign: if it
//     disagrees with the twist, the twists were counter-clockwise, and the wizard asks again instead of flipping silently.

struct CalibrationAxes {
    let up: SIMD3<Double>
    let forward: SIMD3<Double>      // unit, orthogonal to up
}

private let stillGyroDps = 8.0              // raw |ω| below this is "still" (the bias is about 1 dps; the real still span of helper-20261124-125806 stays below 6 once settled)
private let stillAccelG = 0.05              // ... and ||a| - 1| below this (Camera's stillLinearAccelG)
private let stillTiltDegrees = 3.0          // ... and the gravity direction stays within this of the span's first sample: a slow tilt has a small |ω| too
private let stillSeconds = 3.0
private let stepTimeoutSeconds = 15.0
private let maxSampleGapSeconds = 0.5       // a longer hole in the stream breaks the still span
private let burstStartDps = 150.0           // a twist burst starts above this |ω| ...
private let burstEndDps = 50.0              // ... and ends after |ω| stayed below this ...
private let burstEndSeconds = 0.25          // ... this long (the turn-around inside a twist and back is shorter)
private let burstMinPeakDps = 200.0         // a burst that never reached this is a bump, not a twist (recorded twists peak at 360-1200)
private let burstsNeeded = 3
private let lobeDps = 100.0                 // the first lobe is the first ω·axis beyond this
private let maxAxisOffPlaneDegrees = 25.0   // the twist axis must be this close to perpendicular to up
private let tiltDeadbandDps = 10.0          // the pitch angle integrates only above this, so the gyro bias does not walk it
private let tiltSwingDegrees = 10.0         // a pitch swing counts once it covers this angle
private let tiltSwingsNeeded = 2            // raise, lower, raise: enough to know the user did a slow tilt back and forth

private let promptStill = "Calibration: hold the case still in your usual grip…"
private let promptTwist = "Make 3 clockwise twists (and back), with a short pause between them"
private let promptTilt = "Slowly raise and lower the far end of the case twice"

func angleDegrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    acos(max(-1, min(1, dot(a, b) / (length(a) * length(b))))) * 180 / .pi
}

final class Calibration {
    enum Phase { case still, twist, tilt, done }
    private(set) var phase = Phase.still
    private(set) var axes: CalibrationAxes?
    private let withTilt: Bool

    private var prompts: [String] = []
    private var started = false
    private var stepStart: Double?
    private var lastTime: Double?
    private var up = SIMD3<Double>(0, 0, 0)
    private var forward = SIMD3<Double>(0, 0, 0)

    // Step 1
    private var gyroStill = false
    private var runStart: Double?
    private var runAnchor = SIMD3<Double>(0, 0, 0)
    private var runSum = SIMD3<Double>(0, 0, 0)

    // Step 2
    private var burst: [SIMD3<Double>] = []
    private var burstPeak = 0.0
    private var quietSince: Double?
    private var inBurst = false
    private var bursts: [[SIMD3<Double>]] = []

    // Step 3
    private var lastGyroTime: Double?
    private var angle = 0.0, anchor = 0.0, extreme = 0.0
    private var direction = 0.0
    private var swings = 0

    /// `withTilt: false` stops after step 2 (offline check on a recording that has no tilt step).
    init(withTilt: Bool = true) { self.withTilt = withTilt }

    /// Feeds one sample, returns the prompts to show (usually none).
    func feed(_ s: MotionSample) -> [String] {
        prompts = []
        guard phase != .done else { return prompts }
        if !started { started = true; prompts.append(promptStill) }
        if let last = lastTime, s.sensorTime - last > maxSampleGapSeconds { resetRun() }
        lastTime = s.sensorTime
        let begun = stepStart ?? s.sensorTime
        stepStart = begun
        if s.sensorTime - begun > stepTimeoutSeconds {      // no progress: the same step again
            switch phase {
            case .still: begin(.still, "Could not hold still — keep the case still in your usual grip, trying again…")
            case .twist: begin(.twist, "Twists not recognized — make 3 clockwise twists (and back), with a short pause between them")
            default: begin(.tilt, "Tilt not recognized — slowly raise and lower the far end of the case twice")
            }
            return prompts
        }
        switch phase {
        case .still: feedStill(s)
        case .twist: if s.kind == .gyro { feedTwist(s) }
        case .tilt: if s.kind == .gyro { feedTilt(s) }
        case .done: break
        }
        return prompts
    }

    private func begin(_ next: Phase, _ prompt: String?) {
        phase = next
        stepStart = nil
        resetRun()
        burst = []; inBurst = false; quietSince = nil; bursts = []
        lastGyroTime = nil; angle = 0; anchor = 0; extreme = 0; direction = 0; swings = 0
        if let prompt { prompts.append(prompt) }
    }

    private func resetRun() { runStart = nil; runSum = SIMD3(0, 0, 0) }

    // MARK: Step 1

    private func feedStill(_ s: MotionSample) {
        if s.kind == .gyro { gyroStill = length(s.vector) < stillGyroDps; if !gyroStill { resetRun() }; return }
        let a = -s.vector
        guard abs(length(a) - 1) < stillAccelG else { resetRun(); return }
        if runStart != nil, angleDegrees(a, runAnchor) > stillTiltDegrees { resetRun() }
        guard gyroStill else { return }
        if runStart == nil { runStart = s.sensorTime; runAnchor = a }
        runSum += a
        if s.sensorTime - runStart! >= stillSeconds {
            up = runSum / length(runSum)
            begin(.twist, promptTwist)
        }
    }

    // MARK: Step 2

    private func feedTwist(_ s: MotionSample) {
        let w = s.vector, m = length(w)
        if !inBurst {
            guard m > burstStartDps else { return }
            inBurst = true; burst = []; burstPeak = 0; quietSince = nil
        }
        burst.append(w)
        burstPeak = max(burstPeak, m)
        if m < burstEndDps { quietSince = quietSince ?? s.sensorTime } else { quietSince = nil }
        guard let quiet = quietSince, s.sensorTime - quiet >= burstEndSeconds else { return }
        inBurst = false
        guard burstPeak >= burstMinPeakDps else { return }
        bursts.append(burst)
        if bursts.count == burstsNeeded { evaluateTwists() }
    }

    private func evaluateTwists() {
        let all = bursts.flatMap { $0 }
        let peak = all.max { length($0) < length($1) }!
        var v = peak / length(peak)
        for _ in 0..<50 {       // power iteration on the 3×3 covariance Σ ω ωᵀ
            var next = SIMD3<Double>(0, 0, 0)
            for w in all { next += w * dot(w, v) }
            v = next / length(next)
        }
        if abs(dot(v, up)) > sin(maxAxisOffPlaneDegrees * .pi / 180) {
            begin(.twist, "The twist axis is too tilted toward the vertical — repeat 3 clockwise twists (and back)")
            return
        }
        let axis = (v - dot(v, up) * up)
        let unit = axis / length(axis)
        let signs: [Double] = bursts.compactMap { b in b.first { abs(dot($0, unit)) > lobeDps }.map { dot($0, unit) > 0 ? 1 : -1 } }
        guard signs.count == bursts.count, signs.allSatisfy({ $0 == signs[0] }) else {
            begin(.twist, "The twists went in different directions — repeat 3 clockwise twists (and back)")
            return
        }
        forward = unit * signs[0]
        if withTilt { begin(.tilt, promptTilt) } else { finish() }
    }

    // MARK: Step 3

    private func feedTilt(_ s: MotionSample) {
        defer { lastGyroTime = s.sensorTime }
        guard let last = lastGyroTime, s.sensorTime > last else { return }
        let p = dot(s.vector, cross(forward, up))
        if abs(p) > tiltDeadbandDps { angle += p * min(s.sensorTime - last, 0.05) }
        if direction == 0 {
            guard abs(angle - anchor) >= tiltSwingDegrees else { return }
            if angle < anchor {     // lowering first: the twist sign and the tilt disagree, nothing is flipped silently
                begin(.twist, "The twist and tilt directions disagree — repeat the calibration")
                prompts.append(promptTwist)
                return
            }
            direction = 1; extreme = angle
            return
        }
        extreme = direction > 0 ? max(extreme, angle) : min(extreme, angle)
        if (extreme - angle) * direction >= tiltSwingDegrees {
            direction = -direction; extreme = angle; swings += 1
            if swings >= tiltSwingsNeeded { finish() }
        }
    }

    private func finish() {
        axes = CalibrationAxes(up: up, forward: forward)
        phase = .done
    }
}

extension Config {
    /// Writes ONLY neutral_up and forward_axis (3 decimals) into the JSON file, keeping every other key; pretty-printed with
    /// sorted keys like writeDefaultsIfMissing. Returns the rounded vectors so the caller applies exactly what was stored.
    @discardableResult
    static func storeCalibration(_ axes: CalibrationAxes, to url: URL = configURL) -> (up: [Double], forward: [Double]) {
        func rounded(_ v: SIMD3<Double>) -> [Double] { [v.x, v.y, v.z].map { ($0 * 1000).rounded() / 1000 } }
        let up = rounded(axes.up), forward = rounded(axes.forward)
        var dict = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        dict["neutral_up"] = up
        dict["forward_axis"] = forward
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: url)
        }
        return (up, forward)
    }
}

// MARK: Offline

/// Runs steps 1-2 on a helper log (no tilt step in it) and returns the axes; `onPrompt` gets the sensor time of each prompt.
func calibrateLog(_ url: URL, onPrompt: (Double, String) -> Void = { _, _ in }) -> CalibrationAxes? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let wizard = Calibration(withTilt: false)
    for line in text.split(whereSeparator: \.isNewline) {
        guard let s = MotionSample(helperLine: line) else { continue }
        for prompt in wizard.feed(s) { onPrompt(s.sensorTime, prompt) }
        if wizard.phase == .done { break }
    }
    return wizard.axes
}

// Synthetic grips: the raw accelerometer reports gravity DOWN (-up), the gyro adds a constant bias, 200 Hz for both.
private final class CalibrationRig {
    let wizard = Calibration()
    let up: SIMD3<Double>, forward: SIMD3<Double>      // the true grip
    var time = 0.0
    var prompts: [String] = []
    init(up: SIMD3<Double>, forward: SIMD3<Double>) {
        self.up = up / length(up)
        let f = forward - dot(forward, self.up) * self.up
        self.forward = f / length(f)
    }
    var right: SIMD3<Double> { cross(forward, up) }

    func run(_ seconds: Double, gyro: (Double) -> SIMD3<Double> = { _ in SIMD3(0, 0, 0) }) {
        let bias = SIMD3<Double>(1, -0.5, 0.5)
        for i in 0..<Int(seconds * 200) {
            let local = Double(i) / 200, t = time + local
            let a = -up, w = gyro(local) + bias
            prompts += wizard.feed(MotionSample(kind: .accel, sensorTime: t, receivedUptime: t, x: a.x, y: a.y, z: a.z))
            prompts += wizard.feed(MotionSample(kind: .gyro, sensorTime: t, receivedUptime: t, x: w.x, y: w.y, z: w.z))
        }
        time += seconds
    }
    /// Twist about `axis` (first lobe sign `sign`), 0.6 s, then a pause.
    func twist(_ axis: SIMD3<Double>, sign: Double) {
        run(0.6) { axis * (sign * 500 * sin(2 * .pi * $0 / 0.6)) }
        run(0.8)
    }
    /// Slow tilt about the true right axis: first lobe `sign` (+1 raises the far end), two cycles, ~25° each way.
    func tilt(sign: Double) { run(4) { self.right * (sign * 40 * sin(.pi * $0)) } ; run(1) }
    func said(_ text: String) -> Bool { prompts.contains { $0.localizedCaseInsensitiveContains(text) } }
}

func calibrationSelfTest() {
    let up = SIMD3<Double>(-0.008, -0.992, -0.124)
    let fwd = SIMD3<Double>(-0.351, 0.119, -0.929)
    func session(_ rig: CalibrationRig, twists: [Double] = [1, 1, 1], tilt: Double = 1) {
        rig.run(4)
        for sign in twists { rig.twist(rig.forward, sign: sign) }
        rig.tilt(sign: tilt)
        rig.run(0.5)
    }

    // Clockwise twists, raise first → both axes found, in either grip (the second is turned 180° about the vertical).
    for (name, grip) in [("grip A", fwd), ("grip B, 180° turned", -fwd)] {
        let rig = CalibrationRig(up: up, forward: grip)
        session(rig)
        guard let axes = rig.wizard.axes else { preconditionFailure("calibration: \(name) not accepted, prompts \(rig.prompts)") }
        let upErr = angleDegrees(axes.up, rig.up), fwdErr = angleDegrees(axes.forward, rig.forward)
        precondition(upErr < 1 && fwdErr < 1 && abs(dot(axes.forward, axes.up)) < 1e-9, "calibration: \(name) up off \(upErr)°, forward off \(fwdErr)°")
        precondition(rig.prompts.first == promptStill && rig.prompts.contains(promptTwist) && rig.prompts.contains(promptTilt), "calibration: prompts \(rig.prompts)")
        // The stored axes drive the camera: raising the far end must give a positive pitch rate about the stored right axis.
        precondition(dot(rig.right * 40, cross(axes.forward, axes.up)) > 0, "calibration: \(name) pitch sign")
    }

    // Counter-clockwise twists (the symmetric case alone cannot tell) with a raise first: the twist axis comes out flipped,
    // the tilt disagrees → rejected, back to step 2.
    let ccw = CalibrationRig(up: up, forward: fwd)
    session(ccw, twists: [-1, -1, -1])
    precondition(ccw.wizard.axes == nil && ccw.wizard.phase == .twist && ccw.said("disagree"), "calibration: ccw twists + raise must be rejected by the tilt, prompts \(ccw.prompts)")

    // Mixed directions: rejected at step 2.
    let mixed = CalibrationRig(up: up, forward: fwd)
    session(mixed, twists: [1, -1, 1])
    precondition(mixed.wizard.axes == nil && mixed.wizard.phase == .twist && mixed.said("different directions"), "calibration: mixed twists must be rejected, prompts \(mixed.prompts)")

    // Twists about the vertical (the axis is not perpendicular to up): rejected.
    let flat = CalibrationRig(up: up, forward: fwd)
    flat.run(4)
    for _ in 0..<3 { flat.twist(flat.up, sign: 1) }
    precondition(flat.wizard.axes == nil && flat.said("too tilted"), "calibration: twists about the vertical must be rejected")

    // Still shorter than 3 s, then only motion: never accepted, the timeout asks again.
    let shortStill = CalibrationRig(up: up, forward: fwd)
    shortStill.run(2.5)
    shortStill.run(20) { _ in SIMD3(100, 0, 0) }
    precondition(shortStill.wizard.phase == .still && shortStill.wizard.axes == nil && shortStill.said("trying again"), "calibration: a 2.5 s still must not be accepted")

    // Raise-first tilt that is too small (a 9° wobble) is no tilt: step 3 keeps waiting.
    let wobble = CalibrationRig(up: up, forward: fwd)
    wobble.run(4)
    for _ in 0..<3 { wobble.twist(wobble.forward, sign: 1) }
    wobble.run(4) { wobble.right * (15 * sin(2 * .pi * $0 / 2)) }
    precondition(wobble.wizard.phase == .tilt && wobble.wizard.axes == nil, "calibration: a 9° wobble is not a tilt swing")

    var detail = "synthetic grips, ccw, mixed, flat, short still, wobble"
    // Real log: steps 1-2 must reproduce the manual 12:59 axes (skipped when the recording is not there).
    let log = logsFolder.appendingPathComponent("helper-20261124-125806.txt")
    if FileManager.default.fileExists(atPath: log.path) {
        guard let axes = calibrateLog(log) else { preconditionFailure("calibration: no axes from \(log.lastPathComponent)") }
        let upErr = angleDegrees(axes.up, SIMD3(-0.008, -0.992, -0.124)), fwdErr = angleDegrees(axes.forward, SIMD3(-0.351, 0.119, -0.929))
        precondition(upErr < 5 && fwdErr < 5, "calibration: real log up off \(upErr)°, forward off \(fwdErr)° from the manual axes")
        detail += String(format: ", real log up %.1f° forward %.1f° from manual", upErr, fwdErr)
    }

    // Storing touches only the two axes.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("minepointer-calib-test.json")
    try? #"{"gain": 5, "neutral_up": [1, 0, 0], "forward_axis": [0, 1, 0]}"#.data(using: .utf8)!.write(to: tmp)
    let stored = Config.storeCalibration(CalibrationAxes(up: SIMD3(0, 0, 1), forward: SIMD3(0.12345, 0.98765, 0)), to: tmp)
    let c = Config.load(from: tmp)
    precondition(c.gain == 5 && c.neutralUp == [0, 0, 1] && c.forwardAxis == [0.123, 0.988, 0] && stored.forward == c.forwardAxis, "calibration: storeCalibration changed more than the axes")
    try? FileManager.default.removeItem(at: tmp)
    print("PASS: calibration (\(detail))")
}
