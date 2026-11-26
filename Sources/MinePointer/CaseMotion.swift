import Foundation
import simd

// How each gesture moves the case, as keyframed poses: the one source for the README animations and the app's demos
// (App/CaseScene.swift draws them). The self-test turns every clip into the IMU stream the earbuds would send and runs it through
// Camera + GestureDetector, so a demo always shows a motion that the detector accepts as that gesture.
//
// World axes are SceneKit's: x right, y up, z toward the player. The case is held upright with its front toward the screen (-z).

/// A pose of the case: position in metres, angles in degrees applied roll, then pitch, then yaw.
struct CasePose {
    var position = SIMD3<Double>()
    var yaw = 0.0           // turn right +
    var pitch = 0.0         // front up +
    var roll = 0.0          // clockwise seen from behind + (the twist of the calibration)
    var lid = 0.0           // 0 closed, 1 open (the connection steps); the IMU does not see it

    var rotation: simd_quatd {
        let rad = Double.pi / 180
        return simd_quatd(angle: yaw * rad, axis: [0, -1, 0]) * simd_quatd(angle: pitch * rad, axis: [1, 0, 0])
            * simd_quatd(angle: roll * rad, axis: [0, 0, -1])
    }

    static func + (a: CasePose, b: CasePose) -> CasePose {
        CasePose(position: a.position + b.position, yaw: a.yaw + b.yaw, pitch: a.pitch + b.pitch, roll: a.roll + b.roll, lid: a.lid + b.lid)
    }
    static func * (a: CasePose, k: Double) -> CasePose {
        CasePose(position: a.position * k, yaw: a.yaw * k, pitch: a.pitch * k, roll: a.roll * k, lid: a.lid * k)
    }
}

/// A hint drawn beside the case: a straight arrow along a world direction, or a curved one about a world axis (right-handed);
/// `both` puts a head on each end.
enum CaseCue {
    case move(SIMD3<Double>, both: Bool = false)
    case turn(SIMD3<Double>, both: Bool = false)
}

struct CaseClip {
    let id: String                          // file name of the README animation
    let keys: [(t: Double, pose: CasePose)] // real time in seconds from 0; the clip loops after the last
    let expect: [String]                    // what the detector reports for it (GestureName raw values, "pause", "resume")
    var cue: CaseCue?
    var aims = false                        // the crosshair on the screen follows the turns (the camera clip); gestures never aim
    var table: Double?                      // height of a table top under the case (the pause clip)

    /// From `start` (rest), each step moves to its pose in its duration; `nil` holds the pose before.
    init(_ id: String, expect: [String] = [], cue: CaseCue? = nil, aims: Bool = false, table: Double? = nil, start: CasePose = CasePose(),
         _ steps: [(Double, CasePose?)]) {
        var keys = [(t: 0.0, pose: start)]
        for (dt, pose) in steps { keys.append((keys.last!.t + dt, pose ?? keys.last!.pose)) }
        self.id = id; self.keys = keys; self.expect = expect; self.cue = cue; self.aims = aims; self.table = table
    }

    var duration: Double { keys.last!.t }

    /// Between two keys the case follows a minimum-jerk path: zero velocity and acceleration at each key, like a hand.
    func pose(at time: Double) -> CasePose {
        let t = min(max(time, 0), duration)
        guard let i = keys.firstIndex(where: { $0.t >= t }), i > 0 else { return keys[0].pose }
        let a = keys[i - 1], b = keys[i]
        let s = (t - a.t) / (b.t - a.t)
        let e = s * s * s * (10 - 15 * s + 6 * s * s)
        return a.pose + (b.pose + a.pose * -1) * e
    }

    /// The clips one after another (each starts and ends at restPose).
    static func + (a: CaseClip, b: CaseClip) -> CaseClip {
        var steps: [(Double, CasePose?)] = []
        for clip in [a, b] { for i in clip.keys.indices.dropFirst() { steps.append((clip.keys[i].t - clip.keys[i - 1].t, clip.keys[i].pose)) } }
        return CaseClip(a.id + "+" + b.id, expect: a.expect + b.expect, steps)
    }
}

// Speeds and sizes follow the recorded takes (Types.swift): jerks reach 1.6 g in 120 ms, twists 60° at up to 750 dps and back
// within 300 ms, the shake five such jerks at 3.7 Hz, and every gesture starts from a calm hold (arm_calm_ms).
private let restPose = CasePose()

extension CaseClip {
    /// Slow turns: right and back, then the far end up and back. The crosshair on the screen follows.
    static let camera = CaseClip("camera", aims: true, [
        (0.6, nil), (1.1, CasePose(yaw: 25)), (0.3, nil), (1.1, restPose), (0.3, nil),
        (0.9, CasePose(pitch: 15)), (0.3, nil), (0.9, restPose), (0.6, nil),
    ])
    /// Left click: a sharp 4 cm flick down, the far end dipping a little, then back at an easy pace.
    static let jerkDown = CaseClip("jerk-down", expect: ["jerk_down"], cue: .move([0, -1, 0]), [
        (0.9, nil), (0.12, CasePose(position: [0, -0.04, 0], pitch: -12)), (0.88, restPose), (0.7, nil),
    ])
    /// Left button held: jerk downs in a row, each the flick of a click (4 cm down, the far end dipping) and straight back up;
    /// the button comes up when they stop.
    static let shake = CaseClip("shake", expect: ["jerk_down", "shake", "shake_end"], cue: .move([0, -1, 0]), [(0.9, nil)]
        + (0..<5).flatMap { _ in [(0.12, CasePose(position: [0, -0.04, 0], pitch: -12)), (0.15, restPose)] as [(Double, CasePose?)] }
        + [(1.0, nil)])
    /// Right click (or the bow shot while the right button is latched): the mirror of the jerk down.
    static let jerkUp = CaseClip("jerk-up", expect: ["jerk_up"], cue: .move([0, 1, 0]), [
        (0.9, nil), (0.12, CasePose(position: [0, 0.04, 0], pitch: 12)), (0.88, restPose), (0.7, nil),
    ])
    /// Right button latched: a sharp 6 cm pull toward you, without turning the case, then back.
    static let pull = CaseClip("pull", expect: ["pull"], cue: .move([0, 0, 1]), [
        (0.9, nil), (0.15, CasePose(position: [0, 0, 0.06])), (0.95, restPose), (0.7, nil),
    ])
    /// Wheel: a quick clockwise twist and back (next slot), then counter-clockwise and back (previous slot).
    static let twist = CaseClip("twist", expect: ["twist_next", "twist_previous"], cue: .turn([0, 0, -1], both: true), [
        (0.9, nil), (0.15, CasePose(roll: 60)), (0.3, restPose), (0.9, nil), (0.15, CasePose(roll: -60)), (0.3, restPose), (0.8, nil),
    ])
    /// Pause: lay the case on its back on the table, leave it for a moment, pick it up again.
    static let pause = CaseClip("pause", expect: ["pause", "resume"], table: -0.06, [
        (0.6, nil), (1.3, CasePose(position: [0, -0.0495, 0], roll: 90)), (1.8, nil), (1.1, restPose), (0.9, nil),
    ])

    static let all = [camera, jerkDown, shake, jerkUp, pull, twist, pause]

    // Connecting (CaseSession's lid steps): the lid opens and stays up, or closes and stays shut; the README shows both in a row.
    static let lidOpen = CaseClip("lid-open", [(0.7, nil), (0.9, CasePose(lid: 1)), (1.8, nil)])
    static let lidClose = CaseClip("lid-close", start: CasePose(lid: 1), [(0.7, nil), (0.9, restPose), (1.8, nil)])
    static let connect = CaseClip("connect", [(0.7, nil), (0.9, CasePose(lid: 1)), (1.0, nil), (0.9, restPose), (1.2, nil)])

    // The calibration wizard (Calibration.swift), one clip per step.
    static let calibrationStill = CaseClip("calibration-still", [(3.5, nil)])
    static let calibrationTwists = CaseClip("calibration-twists", cue: .turn([0, 0, -1]),
        (0..<3).flatMap { _ in [(0.6, nil), (0.15, CasePose(roll: 60)), (0.3, restPose)] as [(Double, CasePose?)] } + [(0.8, nil)])
    static let calibrationTilt = CaseClip("calibration-tilt", cue: .turn([1, 0, 0], both: true), [
        (0.5, nil), (1.0, CasePose(pitch: 20)), (1.0, restPose), (1.0, CasePose(pitch: 20)), (1.0, restPose), (0.5, nil),
    ])
}

// MARK: Synthetic IMU

/// The case axes x, y, z (right, up, back) in the sensor frame, from the calibrated axes.
func caseFrame(_ config: Config) -> simd_double3x3 {
    var up = SIMD3(config.neutralUp[0], config.neutralUp[1], config.neutralUp[2])
    up /= length(up)
    var fwd = SIMD3(config.forwardAxis[0], config.forwardAxis[1], config.forwardAxis[2])
    fwd -= dot(fwd, up) * up
    fwd /= length(fwd)
    return simd_double3x3(columns: (cross(fwd, up), up, -fwd))
}

/// The samples the earbuds would send for `clip`, after `rest` seconds of holding still, at 200 Hz (accel and gyro at the same
/// instants). The case frame maps onto the sensor frame through the calibrated axes, as Camera.swift reads them.
func caseSamples(_ clip: CaseClip, config: Config, rest: Double = 1.5) -> [MotionSample] {
    let sensor = caseFrame(config)
    let h = 0.0025
    var samples: [MotionSample] = []
    var t = 0.0
    while t < rest + clip.duration {
        let at = t - rest
        let p0 = clip.pose(at: at - h), p1 = clip.pose(at: at), p2 = clip.pose(at: at + h)
        let change: SIMD3<Double> = p2.position - p1.position * 2 + p0.position
        let accel: SIMD3<Double> = change / (h * h * 9.81) + SIMD3<Double>(0, 1, 0)                // specific force in g, "up" at rest
        let turn = p2.rotation * p0.rotation.inverse                                                // world-frame rotation over 2h
        let omega = turn.angle < 1e-12 ? SIMD3<Double>() : turn.axis * (turn.angle / (2 * h) * 180 / .pi)
        let q = p1.rotation.inverse
        let a = sensor * q.act(accel), w = sensor * q.act(omega)
        let recv = t + 0.002
        // The sensor reports accel negated (Apple: gravity points down); the gyro is right-handed, raw.
        samples.append(MotionSample(kind: .accel, sensorTime: t, receivedUptime: recv, x: -a.x, y: -a.y, z: -a.z))
        samples.append(MotionSample(kind: .gyro, sensorTime: t, receivedUptime: recv, x: w.x, y: w.y, z: w.z))
        t += 0.005
    }
    return samples
}

/// Runs a clip through Camera + GestureDetector at a 240 Hz output clock, like the engine: the gestures it reports (a twist as
/// twist_next / twist_previous, from its wheel step), when (clip time, seconds), and the camera counts it posts.
func detect(_ clip: CaseClip, config: Config = Config()) -> (labels: [String], times: [Double], dx: Int, dy: Int) {
    let camera = Camera(config: config), detector = GestureDetector(config: config)
    let rest = 1.5, lag = 0.002          // caseSamples' calm lead-in and arrival lag
    var labels: [String] = [], times: [Double] = [], dx = 0, dy = 0
    func apply(_ events: [GestureEvent], at uptime: Double) {
        func add(_ label: String) { labels.append(label); times.append(uptime - lag - rest) }
        for e in events {
            switch e {
            case .recognized(.twist): break
            case .recognized(let name): add(name.rawValue)
            case .action(.scroll(let dir)): add(dir > 0 ? "twist_next" : "twist_previous")
            case .action(.pause): add("pause")
            case .action(.resume): add("resume"); camera.unmask(keepBand: false)
            case .maskStart(let from): camera.mask(from: from)
            case .rollback(let from): let back = camera.rollback(from: from); dx += back.dx; dy += back.dy
            case .maskEnd: camera.unmask()
            case .action: break
            }
        }
    }
    var tick = 0.0
    for s in caseSamples(clip, config: config, rest: rest) {
        while tick <= s.receivedUptime {
            let c = camera.tick(now: tick); dx += c.dx; dy += c.dy
            apply(detector.tick(now: tick), at: tick)
            tick += 1 / 240
        }
        if let frame = camera.feed(s) { apply(detector.feed(frame, now: s.receivedUptime), at: s.receivedUptime) }
    }
    return (labels, times, dx, dy)
}

/// The other way round, for the sandbox: the case pose from the live stream. The gyro turns the case; the accelerometer pulls the
/// tilt back to gravity, and the heading drifts back toward the screen (nothing measures it, and the camera only uses turns).
/// The position is not measured either (double-integrated acceleration drifts): a damped spring pushed by the linear acceleration
/// shows jerks and pulls as a short kick that settles back.
struct CasePoseTracker {
    private(set) var rotation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)     // case → world
    private(set) var position = SIMD3<Double>()
    private var velocity = SIMD3<Double>()
    private var lastGyro: Double?, lastAccel: Double?

    private static let tiltGain = 0.02          // share of the tilt error corrected per accel sample (~0.25 s at 200 Hz)
    private static let headingReturn = 0.5      // 1/s
    private static let springHz = 2.0

    mutating func feed(_ s: MotionSample, config: Config) {
        let v = caseFrame(config).transpose * s.vector       // in case axes
        switch s.kind {
        case .gyro:
            defer { lastGyro = s.sensorTime }
            guard let last = lastGyro, s.sensorTime > last, s.sensorTime - last < 0.1 else { return }
            let dt = s.sensorTime - last, w = v * (.pi / 180)
            if length(w) > 0 { rotation = (rotation * simd_quatd(angle: length(w) * dt, axis: normalize(w))).normalized }
            let f = rotation.act([0, 0, -1])
            let heading = atan2(f.x, -f.z)                    // right +; weighted by the horizontal share, undefined pointing straight up
            let level = (f.x * f.x + f.z * f.z).squareRoot()
            rotation = (simd_quatd(angle: heading * level * Self.headingReturn * dt, axis: [0, 1, 0]) * rotation).normalized
        case .accel:
            defer { lastAccel = s.sensorTime }
            let force = rotation.act(-v)                       // the sensor reports accel negated; at rest this is "up", 1 g
            if abs(length(force) - 1) < 0.15 {
                let axis = cross(normalize(force), [0, 1, 0])
                if length(axis) > 1e-9 { rotation = (simd_quatd(angle: asin(min(length(axis), 1)) * Self.tiltGain, axis: normalize(axis)) * rotation).normalized }
            }
            guard let last = lastAccel, s.sensorTime > last, s.sensorTime - last < 0.1 else { return }
            let dt = s.sensorTime - last, w0 = 2 * Double.pi * Self.springHz
            let push: SIMD3<Double> = (force - SIMD3<Double>(0, 1, 0)) * 9.81           // split up: CI's compiler times out on one line
            let pull: SIMD3<Double> = position * (w0 * w0) + velocity * (2 * w0)
            velocity += (push - pull) * dt
            position += velocity * dt
        }
    }
}

/// `--clip-poses`: every gesture clip as one JSON line, for tools/fake-engine.py: its poses at 30 a second (x, y, z, qx, qy, qz, qw,
/// as in "@pose" lines) and the gestures the detector reports for it, with their clip times.
func printClipPoses() {
    for clip in CaseClip.all {
        let found = detect(clip)
        let poses = (0..<Int(clip.duration * 30)).map { i -> [Double] in
            let p = clip.pose(at: Double(i) / 30), q = p.rotation
            return [p.position.x, p.position.y, p.position.z, q.imag.x, q.imag.y, q.imag.z, q.real].map { ($0 * 10000).rounded() / 10000 }
        }
        let line: [String: Any] = ["id": clip.id, "events": zip(found.times, found.labels).map { [$0.0, $0.1] }, "poses": poses]
        print(String(data: try! JSONSerialization.data(withJSONObject: line), encoding: .utf8)!)
    }
}

func caseMotionSelfTest() {
    // The synthetic stream itself: at rest the accel is gravity along neutral_up (negated), and a pure yaw turns about it.
    let config = Config()
    let still = CaseClip("still", [(1, nil)])
    let rest = caseSamples(still, config: config)[0]
    precondition(abs(-rest.x - config.neutralUp[0] / length(SIMD3(config.neutralUp[0], config.neutralUp[1], config.neutralUp[2]))) < 1e-6)
    let yaw = CaseClip("yaw", [(1, CasePose(yaw: 30))])
    let turned = detect(yaw)
    precondition(turned.dx > 0 && abs(turned.dy) < turned.dx / 20, "yaw right must move the camera right: \(turned)")
    for clip in CaseClip.all {
        let result = detect(clip)
        precondition(result.labels == clip.expect, "\(clip.id): detector reports \(result.labels), the demo shows \(clip.expect)")
    }
    // The calibration clips, one after another, calibrate to the axes they were made with.
    let wizard = Calibration()
    var reached: [Calibration.Phase: Double] = [:]          // the ring's furthest point in each step
    for s in caseSamples(.calibrationStill + .calibrationTwists + .calibrationTilt, config: config, rest: 0) {
        let phase = wizard.phase
        _ = wizard.feed(s)
        reached[phase] = max(reached[phase] ?? 0, wizard.phase == phase ? wizard.progress : 1)
    }
    precondition(reached[.still] == 1 && reached[.twist] == 1 && reached[.tilt] == 1, "calibration progress \(reached)")
    guard let axes = wizard.axes else { preconditionFailure("the calibration clips do not finish the wizard") }
    let up = SIMD3(config.neutralUp[0], config.neutralUp[1], config.neutralUp[2]), fwd = SIMD3(config.forwardAxis[0], config.forwardAxis[1], config.forwardAxis[2])
    precondition(angleDegrees(axes.up, up) < 2 && angleDegrees(axes.forward, fwd - dot(fwd, up) / dot(up, up) * up) < 5,
                 "calibration clips give up \(axes.up), forward \(axes.forward)")
    // The sandbox's tracker follows the clips' turns (no heading in them) and kicks the right way on a jerk.
    for clip in [CaseClip.twist, .pause, .calibrationTilt, .jerkDown] {
        var tracker = CasePoseTracker()
        var worst = 0.0, lowest = 0.0
        for s in caseSamples(clip, config: config) {
            tracker.feed(s, config: config)
            guard s.kind == .accel else { continue }
            let truth = clip.pose(at: s.sensorTime - 1.5).rotation
            worst = max(worst, (tracker.rotation * truth.inverse).angle * 180 / .pi)
            lowest = min(lowest, tracker.position.y)
        }
        precondition(worst < 6, "tracker off by \(worst)° in \(clip.id)")
        if clip.id == "jerk-down" { precondition(lowest < -0.01 && abs(tracker.position.y) < 0.003, "jerk down kick \(lowest), ends at \(tracker.position.y)") }
    }
    print("PASS: case motion clips (\(CaseClip.all.count) gestures, 3 calibration steps) match the detector and the calibration; the pose tracker follows them")
}
