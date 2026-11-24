import Foundation

// Camera pipeline: gyro/accel samples → mouse counts.
//
// Output convention: counts are mouse deltas in screen coordinates, so dx > 0 turns the camera right
// and dy > 0 moves the mouse down (the camera looks down). `invertY` flips dy.
//
// Sign convention (Apple's, verified on the recordings and live):
//  - The accelerometer reports gravity pointing DOWN at rest (like an iPhone: flat on a table z = -1). It is negated on
//    input, so `gravity` points UP and `linear` is the kinematic acceleration.
//  - The gyro is right-handed and used as is.
//  - An earlier build assumed "accel up" and compensated by negating the gyro and the forward axis: that fixed yaw but
//    left pitch inverted (live check). Evidence for the current convention: with it, the clockwise-twist axis
//    points toward the screen, pushes start with acceleration toward the screen (26/26), pulls away (25/25).
//  - ω·up > 0 is counter-clockwise from above (turning left), so dx = -(ω·up).
//  - right = forward × up (x right, y up, z back: (-z) × y = x). ω·right > 0 raises the front of the case, so the camera
//    looks up, which is a mouse move up (dy < 0). dy = -(ω·right).
//  - Forward is config.forwardAxis made orthogonal to up: the clockwise-twist axis, pointing toward the screen.

// Local constants (not in Config yet; candidates for config fields).
private let gravityTauSeconds = 0.3        // gravity low-pass time constant
private let gravityAcceptG = 0.1           // accel samples with ||a| - 1| above this are not used for gravity
private let stillLinearAccelG = 0.05       // "still" needs ||a| - 1| below this
private let stillTiltDegrees = 0.5         // "still" needs gravity to move less than this since the window start
private let maxPlausibleBiasDps = 2.0      // measured gyro bias is about 1 dps (0.24, 0.96, 0.26)
private let biasTauSeconds = 3.0           // bias EMA time constant while still
private let oneEuroDerivativeCutoffHz = 1.0
private let maxSensorDt = 0.05             // a larger sensor-time gap is treated as one nominal step
private let nominalDt = 0.005
private let offsetCreepPerSecond = 1e-4    // lets the min-tracked arrival offset follow clock drift upwards

/// Soft deadzone on the 2-D rate: below `threshold` the magnitude m becomes m·m/threshold. Continuous at the threshold.
func softDeadzone(_ v: SIMD2<Double>, threshold: Double) -> SIMD2<Double> {
    let m = (v.x * v.x + v.y * v.y).squareRoot()
    guard threshold > 0, m < threshold else { return v }
    return v * (m / threshold)
}

func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
func length(_ a: SIMD3<Double>) -> Double { dot(a, a).squareRoot() }

/// What the gesture detector needs from the camera's own estimates, once per gyro sample (sensor time).
/// Axes are unit vectors in the sensor frame; omega is right-handed and bias-corrected (deg/s); linear is
/// acceleration with the gravity estimate removed (g), so it is the true acceleration of the case.
/// `up` is the world vertical (gravity), `axis` the case-fixed up axis (config.neutralUp): a jerk is a wrist flick and the case
/// moves along its own axis, so "down" is measured along `axis`, not along the world vertical (they differ by the tilt).
struct GestureFrame {
    let time: Double
    let up: SIMD3<Double>
    let axis: SIMD3<Double>
    let forward: SIMD3<Double>      // toward the screen, orthogonal to up
    let right: SIMD3<Double>        // forward × up
    let linear: SIMD3<Double>
    let omega: SIMD3<Double>

    var down: Double { -dot(linear, axis) }          // > 0 while the case accelerates along -axis (a jerk down)
    var forwardAccel: Double { dot(linear, forward) }
    var rightAccel: Double { dot(linear, right) }
    var roll: Double { dot(omega, forward) }
}

/// 1€ filter (Casiez et al. 2012) for one signal, with sensor-time dt.
private struct OneEuroFilter {
    var x: Double?
    var dx = 0.0

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func filter(_ value: Double, dt: Double, minCutoff: Double, beta: Double) -> Double {
        guard let prev = x else { x = value; return value }
        let rawDx = (value - prev) / dt
        dx += Self.alpha(cutoff: oneEuroDerivativeCutoffHz, dt: dt) * (rawDx - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let out = prev + Self.alpha(cutoff: cutoff, dt: dt) * (value - prev)
        x = out
        return out
    }
}

final class Camera {
    var config: Config

    // Gravity / axes
    private var gravity: SIMD3<Double>?
    private var lastLinearDev = 0.0
    private var lastAccelT: Double?

    // Gyro bias learning
    private var bias: SIMD3<Double>?
    private var stillStart: Double?
    private var stillAnchor = SIMD3<Double>(0, 0, 0)
    private var stillSum = SIMD3<Double>(0, 0, 0)
    private var stillCount = 0
    private var stillNow = false
    private var lastGyroT: Double?

    // Filter and output
    private var yawFilter = OneEuroFilter()
    private var pitchFilter = OneEuroFilter()
    private var arrivalOffset: Double?     // min-tracked (receivedUptime - sensorTime)
    private var lastSensorT: Double?
    private var lastDue = -Double.infinity
    private var queue: [(due: Double, sensor: Double, dx: Double, dy: Double)] = []
    private var emitted: [(sensor: Double, dx: Double, dy: Double)] = []   // output already given out, for rollback()
    private var latestLinear = SIMD3<Double>(0, 0, 0)
    private var maskFrom: Double?          // sensor time; gyro samples from here on produce no output while set
    // Gesture backlash band and recovery zone. maskedSum is the output the case's rotation since the gesture's calm exit
    // would have produced (counts: masked samples, dropped queue, rolled-back output). After the mask, for gestureReturnMs,
    // the case's pose p is tracked relative to its pre-gesture pose (0; it starts at maskedSum). The aim moves by G(p) with
    // G' = 0 inside the band between the pre-gesture and the post-gesture pose (returning, braking and wobbling there is
    // absorbed in both directions, so it cannot ratchet the aim: a one-directional "debt" did exactly that), G' = recoveryGain
    // within ±recoveryZoneDeg of the pre-gesture pose (the hand recovers and wobbles there, below calm_dps, and used to
    // reach the aim at full gain), and G' = 1 elsewhere. G is a function of the pose, so any wobble that returns to a pose
    // returns the aim to what it was.
    private var maskedSum = SIMD2<Double>(0, 0)
    private var bandPos = SIMD2<Double>(0, 0)
    private var bandLo = SIMD2<Double>(0, 0)
    private var bandHi = SIMD2<Double>(0, 0)
    private var bandUntil = -Double.infinity   // sensor time
    private var zoneUntil = -Double.infinity   // the recovery zone ends before the band (recoveryZoneMs): after it G' = 1 outside the band
    private var zone = 0.0                     // recoveryZoneDeg in counts
    private var head = 0
    private var carry = SIMD2<Double>(0, 0)

    init(config: Config) { self.config = config }

    var isStill: Bool { stillNow }

    func reset() {
        gravity = nil; lastLinearDev = 0; lastAccelT = nil
        bias = nil; stillStart = nil; stillSum = SIMD3(0, 0, 0); stillCount = 0; stillNow = false
        lastGyroT = nil
        yawFilter = OneEuroFilter(); pitchFilter = OneEuroFilter()
        arrivalOffset = nil; lastSensorT = nil; lastDue = -Double.infinity
        queue.removeAll(); head = 0; carry = SIMD2(0, 0)
        latestLinear = SIMD3(0, 0, 0); maskFrom = nil; emitted.removeAll()
        maskedSum = SIMD2(0, 0); bandUntil = -Double.infinity; zoneUntil = -Double.infinity
    }

    /// Returns a frame for every gyro sample once gravity is known; nil otherwise.
    @discardableResult
    func feed(_ s: MotionSample) -> GestureFrame? {
        trackOffset(s)
        switch s.kind {
        case .accel: feedAccel(s); return nil
        case .gyro: return feedGyro(s)
        }
    }

    /// A gesture started: drop queued output with sensor time ≥ `time` and everything that arrives until `unmask`.
    /// Output already emitted cannot be taken back, so the caller passes a time a little before the gesture onset.
    func mask(from time: Double) {
        if maskFrom == nil { maskedSum = SIMD2(0, 0); bandUntil = -Double.infinity }
        maskFrom = min(maskFrom ?? time, time)
        for q in queue[head...] where q.sensor >= time { maskedSum += SIMD2(q.dx, q.dy) }
        queue = queue[head...].filter { $0.sensor < time }
        head = 0
    }

    /// The case has settled: output resumes with the next gyro sample. Nothing masked is replayed, and the filters
    /// start fresh so the first output after the gesture does not inherit the gesture's motion.
    /// `keepBand: false` (pick-up after a pause) forgets the masked rotation instead of absorbing it: the case moved a
    /// quarter turn between the table and the hand, a band that wide would freeze the aim for gestureReturnMs.
    func unmask(keepBand: Bool = true) {
        guard maskFrom != nil else { return }
        maskFrom = nil
        bandPos = maskedSum
        bandLo = SIMD2(min(0, maskedSum.x), min(0, maskedSum.y))
        bandHi = SIMD2(max(0, maskedSum.x), max(0, maskedSum.y))
        bandUntil = keepBand ? (lastGyroT ?? 0) + config.gestureReturnMs / 1000 : -Double.infinity
        zoneUntil = (lastGyroT ?? 0) + config.recoveryZoneMs / 1000
        zone = config.recoveryZoneDeg * config.gain * config.countsPerDegree
        maskedSum = SIMD2(0, 0)
        yawFilter = OneEuroFilter(); pitchFilter = OneEuroFilter()
    }

    var isMasked: Bool { maskFrom != nil }

    /// Takes back the output already emitted for sensor times ≥ `time`: returns the counts that undo it exactly
    /// (up to the fractional remainder, which stays in the carry). The same output is never rolled back twice.
    func rollback(from time: Double) -> (dx: Int, dy: Int) {
        var sum = SIMD2<Double>(0, 0)
        emitted.removeAll { e in
            guard e.sensor >= time else { return false }
            sum.x += e.dx; sum.y += e.dy
            return true
        }
        carry -= sum
        maskedSum += sum          // taken back from the aim, so it is part of the gesture's rotation
        let dx = Int(carry.x.rounded(.towardZero)), dy = Int(carry.y.rounded(.towardZero))
        carry.x -= Double(dx); carry.y -= Double(dy)
        return (dx, dy)
    }

    /// Counts due at uptime `now`. Remainders below one count stay for the next call.
    func tick(now: Double) -> (dx: Int, dy: Int) {
        while head < queue.count, queue[head].due <= now {
            carry.x += queue[head].dx
            carry.y += queue[head].dy
            emitted.append((queue[head].sensor, queue[head].dx, queue[head].dy))
            head += 1
        }
        if emitted.count > 1024 { emitted.removeFirst(512) }
        if head > 256 { queue.removeFirst(head); head = 0 }
        let dx = Int(carry.x.rounded(.towardZero)), dy = Int(carry.y.rounded(.towardZero))
        carry.x -= Double(dx); carry.y -= Double(dy)
        return (dx, dy)
    }

    // MARK: Time mapping

    /// Min-tracks receivedUptime - sensorTime. A new session (sensor clock jump) starts the estimate again.
    private func trackOffset(_ s: MotionSample) {
        let offset = s.receivedUptime - s.sensorTime
        if let last = lastSensorT, let est = arrivalOffset, s.sensorTime > last - 0.5, s.sensorTime < last + 5 {
            arrivalOffset = min(offset, est + max(0, s.sensorTime - last) * offsetCreepPerSecond)
            lastSensorT = max(last, s.sensorTime)
        } else {
            arrivalOffset = offset
            lastSensorT = s.sensorTime
        }
    }

    // MARK: Accelerometer

    private func feedAccel(_ s: MotionSample) {
        let a = -s.vector   // Apple convention: the accelerometer reports gravity pointing DOWN; negate to "up at rest"
        let mag = length(a)
        lastLinearDev = abs(mag - 1)
        if let g = gravity { latestLinear = a - g }   // also in near free fall (a downward jerk), where gravity is not updated
        guard mag > 0.5 else { return }
        guard let g = gravity, let t0 = lastAccelT, s.sensorTime > t0, s.sensorTime - t0 < 1 else {
            gravity = a; lastAccelT = s.sensorTime; latestLinear = SIMD3(0, 0, 0); return
        }
        lastAccelT = s.sensorTime
        if lastLinearDev < gravityAcceptG {
            let alpha = 1 - exp(-(s.sensorTime - t0) / gravityTauSeconds)
            gravity = g + alpha * (a - g)
        }
        latestLinear = a - gravity!
    }

    // MARK: Gyro

    private func feedGyro(_ s: MotionSample) -> GestureFrame? {
        guard let g = gravity else { return nil }
        var dt = 0.0
        if let last = lastGyroT, s.sensorTime > last { dt = s.sensorTime - last }
        else if lastGyroT != nil, s.sensorTime <= lastGyroT! { lastGyroT = s.sensorTime; return nil }
        lastGyroT = s.sensorTime
        if dt == 0 { return nil }                      // first sample of a stream
        if dt > maxSensorDt { dt = nominalDt }

        let w = s.vector    // right-handed (Apple convention)
        learnBias(w, gravity: g, t: s.sensorTime, dt: dt)

        let up = g / length(g)
        let fwd0 = SIMD3<Double>(config.forwardAxis[0], config.forwardAxis[1], config.forwardAxis[2])
        var fwd = fwd0 - dot(fwd0, up) * up
        guard length(fwd) > 0.1 else { return nil }
        fwd /= length(fwd)
        let right = cross(fwd, up)

        let corrected = w - (bias ?? SIMD3(0, 0, 0))
        let n = SIMD3<Double>(config.neutralUp[0], config.neutralUp[1], config.neutralUp[2])
        let frame = GestureFrame(time: s.sensorTime, up: up, axis: n / length(n), forward: fwd, right: right, linear: latestLinear, omega: corrected)
        guard bias != nil else { return frame }        // no camera output before the first still period
        let cpd = config.countsPerDegree, k = dt * config.gain * cpd
        let raw = SIMD2<Double>(dot(corrected, up), dot(corrected, right))   // (yaw CCW, pitch up), deg/s
        if let from = maskFrom, s.sensorTime >= from {                       // gesture in progress: the aim must not move
            maskedSum += SIMD2(-raw.x * k, (config.invertY ? raw.y : -raw.y) * k)
            return frame
        }
        let dz = softDeadzone(raw, threshold: config.deadzoneDps)
        let yaw = yawFilter.filter(dz.x, dt: dt, minCutoff: config.oneEuroMinCutoff, beta: config.oneEuroBeta)
        let pitch = pitchFilter.filter(dz.y, dt: dt, minCutoff: config.oneEuroMinCutoff, beta: config.oneEuroBeta)

        var dx = -yaw * k                     // turning right = clockwise from above = yaw < 0
        var dy = -pitch * k                   // front up = camera up = mouse up = negative dy
        if config.invertY { dy = -dy }
        if s.sensorTime <= bandUntil {
            let z = s.sensorTime <= zoneUntil ? zone : 0
            dx = throughBand(dx, &bandPos.x, bandLo.x, bandHi.x, zone: z)
            dy = throughBand(dy, &bandPos.y, bandLo.y, bandHi.y, zone: z)
        }

        let offset = arrivalOffset ?? 0
        let due = max(lastDue, s.sensorTime + offset + config.jitterMs / 1000)
        lastDue = due
        queue.append((due, s.sensorTime, dx, dy))
        return frame
    }

    /// Moves the pose by `v` and returns how far the aim moves: G(new) - G(old), G' = 0 in [lo, hi], recoveryGain within
    /// ±zone of the pre-gesture pose and 1 elsewhere. Without a zone or with recoveryGain 1 this is the plain backlash band.
    private func throughBand(_ v: Double, _ pos: inout Double, _ lo: Double, _ hi: Double, zone: Double) -> Double {
        let old = pos, new = pos + v
        pos = new
        func weighted(_ p: Double) -> Double {      // integral of the zone weight from 0 to p
            let inside = min(max(p, -zone), zone)
            return config.recoveryGain * inside + (p - inside)
        }
        func aim(_ p: Double) -> Double { weighted(p) - weighted(min(max(p, lo), hi)) }
        return aim(new) - aim(old)
    }

    /// Bias EMA only while still: small rate, no linear acceleration, gravity not moving, for ≥ biasStillSeconds.
    /// The tilt check keeps slow deliberate aiming (a few dps) from being learned as bias.
    private func learnBias(_ w: SIMD3<Double>, gravity g: SIMD3<Double>, t: Double, dt: Double) {
        let rate = length(w - (bias ?? SIMD3(0, 0, 0)))
        var tilt = 0.0
        if stillStart != nil {
            let c = dot(g, stillAnchor) / (length(g) * length(stillAnchor))
            tilt = acos(min(1, max(-1, c))) * 180 / Double.pi
        }
        let calm = rate < config.biasStillDps && lastLinearDev < stillLinearAccelG && tilt < stillTiltDegrees
        guard calm else {
            stillStart = t; stillAnchor = g; stillSum = SIMD3(0, 0, 0); stillCount = 0; stillNow = false
            return
        }
        if stillStart == nil { stillStart = t; stillAnchor = g }
        stillSum += w; stillCount += 1
        guard t - stillStart! >= config.biasStillSeconds else { return }
        stillNow = true
        // Updates are stricter than "still": a slow deliberate yaw of 2-3 dps leaves no trace in the accelerometer,
        // so only samples close to the current bias (or a window mean close to zero at init) are learned.
        let learnDps = config.biasStillDps / 3
        if let b = bias {
            if rate < learnDps { bias = b + (1 - exp(-dt / biasTauSeconds)) * (w - b) }
        } else {
            let mean = stillSum / Double(stillCount)
            if length(mean) < maxPlausibleBiasDps { bias = mean }
            else { stillStart = t; stillAnchor = g; stillSum = SIMD3(0, 0, 0); stillCount = 0; stillNow = false }
        }
    }
}

// MARK: Self-test

/// Feeds a synthetic 200 Hz stream, ticks at 240 Hz, and sums the output. Arrival = sensor time + 2 ms.
private func synthesize(_ camera: Camera, from t0: Double, seconds: Double, accel: SIMD3<Double>,
                        gyro: (Double) -> SIMD3<Double>) -> (dx: Int, dy: Int) {
    var sx = 0, sy = 0
    let dt = 0.005
    var nextTick = t0
    var t = t0
    while t < t0 + seconds {
        let recv = t + 0.002
        // Tests describe physics (accel = up at rest); the sensor reports accel negated (Apple convention).
        camera.feed(MotionSample(kind: .accel, sensorTime: t, receivedUptime: recv, x: -accel.x, y: -accel.y, z: -accel.z))
        let w = gyro(t - t0)
        camera.feed(MotionSample(kind: .gyro, sensorTime: t, receivedUptime: recv, x: w.x, y: w.y, z: w.z))
        while nextTick <= recv { let c = camera.tick(now: nextTick); sx += c.dx; sy += c.dy; nextTick += 1 / 240 }
        t += dt
    }
    return (sx, sy)
}

func cameraSelfTest() {
    let config = Config()
    let g = SIMD3<Double>(0.02, -0.94, -0.35)
    let up = g / length(g)
    var fwd = SIMD3<Double>(config.forwardAxis[0], config.forwardAxis[1], config.forwardAxis[2])
    fwd -= dot(fwd, up) * up
    fwd /= length(fwd)
    let right = cross(fwd, up)
    let bias = SIMD3<Double>(0.24, 0.96, 0.26)
    let cpd = config.countsPerDegree

    // Deadzone: continuous at the threshold, quadratic below, direction kept.
    let dz = 2.0
    let below = softDeadzone(SIMD2(dz - 1e-9, 0), threshold: dz), above = softDeadzone(SIMD2(dz + 1e-9, 0), threshold: dz)
    precondition(abs(below.x - above.x) < 1e-8)
    let half = softDeadzone(SIMD2(0.6, 0.8), threshold: dz)        // magnitude 1 → 0.5, same direction
    precondition(abs(half.x - 0.3) < 1e-12 && abs(half.y - 0.4) < 1e-12)

    // Constant bias, no motion: zero output after warm-up.
    var cam = Camera(config: config)
    _ = synthesize(cam, from: 0, seconds: 3, accel: g) { _ in bias }
    let still = synthesize(cam, from: 3, seconds: 5, accel: g) { _ in bias }
    precondition(still.dx == 0 && still.dy == 0, "bias not removed: \(still)")
    precondition(cam.isStill)

    // Constant yaw rate to the right (clockwise from above): counts ≈ gain × cpd × degrees, dx > 0, dy ≈ 0.
    let rate = 30.0, seconds = 20.0
    cam = Camera(config: config)
    _ = synthesize(cam, from: 0, seconds: 3, accel: g) { _ in bias }
    var c = synthesize(cam, from: 3, seconds: seconds, accel: g) { _ in bias - rate * up }
    let drain = synthesize(cam, from: 3 + seconds, seconds: 3, accel: g) { _ in bias }
    c.dx += drain.dx; c.dy += drain.dy
    let expected = rate * seconds * config.gain * cpd
    precondition(c.dx > 0 && abs(Double(c.dx) / expected - 1) < 0.02, "yaw counts \(c.dx), expected \(expected)")
    precondition(abs(c.dy) <= 2, "yaw leaked into pitch: \(c.dy)")

    // Pitch: front of the case up → camera up → negative dy (mouse up), and invertY flips it.
    cam = Camera(config: config)
    _ = synthesize(cam, from: 0, seconds: 3, accel: g) { _ in bias }
    var p = synthesize(cam, from: 3, seconds: seconds, accel: g) { _ in bias + rate * right }
    let pd = synthesize(cam, from: 3 + seconds, seconds: 3, accel: g) { _ in bias }
    p.dx += pd.dx; p.dy += pd.dy
    precondition(p.dy < 0 && abs(Double(-p.dy) / expected - 1) < 0.02, "pitch counts \(p.dy), expected \(-expected)")
    precondition(abs(p.dx) <= 2, "pitch leaked into yaw: \(p.dx)")
    var inverted = config; inverted.invertY = true
    cam = Camera(config: inverted)
    _ = synthesize(cam, from: 0, seconds: 3, accel: g) { _ in bias }
    let pi2 = synthesize(cam, from: 3, seconds: 5, accel: g) { _ in bias + rate * right }
    precondition(pi2.dy > 0, "invertY did not flip dy")

    // Roll alone (rotation about forward) produces no output.
    cam = Camera(config: config)
    _ = synthesize(cam, from: 0, seconds: 3, accel: g) { _ in bias }
    let roll = synthesize(cam, from: 3, seconds: 5, accel: g) { _ in bias + 100 * fwd }
    precondition(abs(roll.dx) <= 1 && abs(roll.dy) <= 1, "roll leaked: \(roll)")

    // Mask: incoming output is dropped while masked, queued output is dropped when the mask starts, and after unmask()
    // the camera resumes with the true rate, without catching up on what was masked.
    cam = Camera(config: config)
    _ = synthesize(cam, from: 0, seconds: 3, accel: g) { _ in bias }
    for i in 0..<8 {      // 40 ms of yaw that sits in the jitter buffer, not yet due
        let t = 3 + Double(i) * 0.005
        cam.feed(MotionSample(kind: .accel, sensorTime: t, receivedUptime: t, x: -g.x, y: -g.y, z: -g.z))
        let w = bias - rate * up
        cam.feed(MotionSample(kind: .gyro, sensorTime: t, receivedUptime: t, x: w.x, y: w.y, z: w.z))
    }
    cam.mask(from: 3)
    precondition(cam.isMasked && cam.tick(now: 100) == (0, 0), "queued output survived the mask")
    let masked = synthesize(cam, from: 3.04, seconds: 2, accel: g) { _ in bias - rate * up }
    precondition(masked.dx == 0 && masked.dy == 0, "masked output leaked: \(masked)")
    cam.unmask()
    precondition(!cam.isMasked)
    var after = synthesize(cam, from: 5.04, seconds: 3, accel: g) { _ in bias - rate * up }
    let tail = synthesize(cam, from: 8.04, seconds: 1, accel: g) { _ in bias }
    after.dx += tail.dx
    let expectedAfter = rate * 3 * config.gain * cpd
    precondition(after.dx > 0 && abs(Double(after.dx) / expectedAfter - 1) < 0.05, "after unmask \(after.dx), expected \(expectedAfter)")

    // Backlash band: the case tilts front-down during a masked gesture, then the hand brings it back up. The return
    // must not move the aim; once the band has expired, the same motion moves the aim normally again.
    cam = Camera(config: config)
    _ = synthesize(cam, from: 0, seconds: 3, accel: g) { _ in bias }
    cam.mask(from: 3)
    _ = synthesize(cam, from: 3, seconds: 0.3, accel: g) { _ in bias - 60 * right }      // 18° front down, masked
    cam.unmask()
    var back = synthesize(cam, from: 3.3, seconds: 0.3, accel: g) { _ in bias + 60 * right }   // 18° back up
    let backTail = synthesize(cam, from: 3.6, seconds: 1, accel: g) { _ in bias }
    back.dy += backTail.dy
    let freeUp = 18 * config.gain * cpd
    precondition(abs(Double(back.dy)) < 0.1 * freeUp, "return after a gesture moved the aim: dy \(back.dy) of \(freeUp)")
    // Wobble inside the band (down, up, down, up) must not ratchet the aim.
    cam = Camera(config: config)
    _ = synthesize(cam, from: 0, seconds: 3, accel: g) { _ in bias }
    cam.mask(from: 3)
    _ = synthesize(cam, from: 3, seconds: 0.3, accel: g) { _ in bias - 60 * right }
    cam.unmask()
    var wobble = (dx: 0, dy: 0)
    for (i, sign) in [1.0, -1.0, 1.0, -1.0].enumerated() {
        let part = synthesize(cam, from: 3.3 + Double(i) * 0.2, seconds: 0.2, accel: g) { _ in bias + sign * 60 * right }
        wobble.dy += part.dy
    }
    wobble.dy += synthesize(cam, from: 4.1, seconds: 0.5, accel: g) { _ in bias }.dy
    precondition(abs(Double(wobble.dy)) < 0.1 * freeUp, "wobble after a gesture ratcheted the aim: dy \(wobble.dy)")
    _ = synthesize(cam, from: 4.6, seconds: 8, accel: g) { _ in bias }                    // band expires
    var later = synthesize(cam, from: 12.6, seconds: 0.3, accel: g) { _ in bias + 60 * right }
    later.dy += synthesize(cam, from: 12.9, seconds: 1, accel: g) { _ in bias }.dy
    precondition(Double(-later.dy) > 0.9 * freeUp, "expired band still eats aim: dy \(later.dy) of \(freeUp)")

    // unmask(keepBand: false) (pick-up after a pause): no band, the same return motion moves the aim in full.
    cam = Camera(config: config)
    _ = synthesize(cam, from: 0, seconds: 3, accel: g) { _ in bias }
    cam.mask(from: 3)
    _ = synthesize(cam, from: 3, seconds: 0.3, accel: g) { _ in bias - 60 * right }
    cam.unmask(keepBand: false)
    var free = synthesize(cam, from: 3.3, seconds: 0.3, accel: g) { _ in bias + 60 * right }
    free.dy += synthesize(cam, from: 3.6, seconds: 1, accel: g) { _ in bias }.dy
    precondition(Double(-free.dy) > 0.9 * freeUp, "unmask(keepBand: false) still absorbed motion: dy \(free.dy) of \(freeUp)")

    // Recovery zone: after a mask that moved nothing, the case wobbles around its pre-gesture pose. Inside ±recoveryZoneDeg the
    // aim moves by recoveryGain of the normal, beyond it in full. Each leg is `deg` of case rotation (positive = front up) in 0.4 s.
    func recovery(_ cfg: Config, _ legs: [Double]) -> [Double] {
        let c = Camera(config: cfg)
        _ = synthesize(c, from: 0, seconds: 3, accel: g) { _ in bias }
        c.mask(from: 3)
        _ = synthesize(c, from: 3, seconds: 0.2, accel: g) { _ in bias }
        c.unmask()
        var sums: [Double] = []
        for (i, deg) in legs.enumerated() {
            let part = synthesize(c, from: 3.2 + Double(i) * 0.4, seconds: 0.4, accel: g) { _ in bias + (deg / 0.4) * right }
            sums.append(Double(part.dy))
        }
        sums[sums.count - 1] += Double(synthesize(c, from: 3.2 + Double(legs.count) * 0.4, seconds: 0.6, accel: g) { _ in bias }.dy)
        return sums
    }
    let k = config.gain * cpd                       // counts per degree of case rotation
    var zoned = config; zoned.gestureReturnMs = 10_000; zoned.recoveryZoneMs = 10_000      // the legs below must stay inside the return window
    var noZone = zoned; noZone.recoveryGain = 1
    var plain = zoned; plain.recoveryGain = 0
    let wobbleLegs = [8.0, -16, 16, -8]             // stays within ±8° of the pre-gesture pose, well inside the zone (15°)
    let freeWobble = recovery(noZone, wobbleLegs).reduce(0) { $0 + abs($1) }
    precondition(freeWobble > 0.5 * 48 * k, "zone test is void: the free wobble gave \(freeWobble) counts")
    let wob = recovery(zoned, wobbleLegs), wobMirror = recovery(zoned, wobbleLegs.map { -$0 })
    let wobPath = wob.reduce(0) { $0 + abs($1) }, mirrorPath = wobMirror.reduce(0) { $0 + abs($1) }
    precondition(abs(wobPath / freeWobble - config.recoveryGain) < 0.06, "wobble in the zone: \(wobPath / freeWobble) of the free path, expected \(config.recoveryGain)")
    // Symmetric: the mirrored wobble is attenuated alike, and neither direction ratchets the aim.
    precondition(abs(mirrorPath / wobPath - 1) < 0.05, "zone is not symmetric: \(wobPath) vs \(mirrorPath) counts")
    precondition(abs(wob.reduce(0, +)) < 0.03 * wobPath + 3 && abs(wobMirror.reduce(0, +)) < 0.03 * wobPath + 3, "wobble in the zone ratcheted the aim: \(wob.reduce(0, +)) / \(wobMirror.reduce(0, +))")
    // Beyond the zone: the part past ±15° gets the full gain, the part inside is scaled.
    let far = recovery(zoned, [40]).reduce(0, +), farMirror = recovery(zoned, [-40]).reduce(0, +)
    let farExpected = (config.recoveryGain * config.recoveryZoneDeg + (40 - config.recoveryZoneDeg)) * k
    precondition(abs(-far / farExpected - 1) < 0.04 && abs(farMirror / farExpected - 1) < 0.04, "motion beyond the zone: \(far) / \(farMirror) counts, expected ±\(farExpected)")
    let farOnly = recovery(zoned, [15, 25])        // reaches the zone edge, then 25° of full-gain motion
    precondition(abs(-farOnly[1] / (25 * k) - 1) < 0.1, "motion past the zone edge was not at full gain: \(-farOnly[1]) of \(25 * k)")
    // recoveryGain 0 (option B): the zone is absorbed fully, motion beyond it moves the aim only for the part past the edge.
    precondition(recovery(plain, wobbleLegs).reduce(0) { $0 + abs($1) } < 0.03 * freeWobble + 3, "zone with recoveryGain 0 leaked")
    let farPlain = recovery(plain, [40]).reduce(0, +)
    precondition(abs(-farPlain / ((40 - config.recoveryZoneDeg) * k) - 1) < 0.04, "plain zone: \(farPlain) counts for 40° of motion")
    // The zone ends with the return window: afterwards the same wobble moves the aim in full.
    do {
        let c = Camera(config: config)
        _ = synthesize(c, from: 0, seconds: 3, accel: g) { _ in bias }
        c.mask(from: 3)
        _ = synthesize(c, from: 3, seconds: 0.2, accel: g) { _ in bias }
        c.unmask()
        _ = synthesize(c, from: 3.2, seconds: config.gestureReturnMs / 1000 + 0.5, accel: g) { _ in bias }
        var late = synthesize(c, from: 5.2 + config.gestureReturnMs / 1000, seconds: 0.4, accel: g) { _ in bias + (8 / 0.4) * right }
        late.dy += synthesize(c, from: 5.6 + config.gestureReturnMs / 1000, seconds: 0.6, accel: g) { _ in bias }.dy
        precondition(abs(Double(-late.dy) / (8 * k) - 1) < 0.05, "zone still active after the return window: dy \(late.dy) of \(-8 * k)")
    }
    // The zone ends before the band (recoveryZoneMs < gestureReturnMs): the same wobble is attenuated inside the zone window and moves
    // the aim in full after it, while the band is still on (a mask that moved nothing leaves it empty, so it absorbs nothing here).
    do {
        var short = config; short.recoveryZoneMs = 500; short.gestureReturnMs = 1500; short.recoveryGain = 0.5
        func wobbleAt(_ offset: Double) -> Double {
            let c = Camera(config: short)
            _ = synthesize(c, from: 0, seconds: 3, accel: g) { _ in bias }
            c.mask(from: 3)
            _ = synthesize(c, from: 3, seconds: 0.2, accel: g) { _ in bias }
            c.unmask()
            _ = synthesize(c, from: 3.2, seconds: offset, accel: g) { _ in bias }
            var leg = synthesize(c, from: 3.2 + offset, seconds: 0.2, accel: g) { _ in bias + (8 / 0.2) * right }
            leg.dy += synthesize(c, from: 3.4 + offset, seconds: 0.4, accel: g) { _ in bias }.dy
            return Double(-leg.dy) / (8 * k)
        }
        precondition(abs(wobbleAt(0) - 0.5) < 0.06, "inside the zone window the gain is recoveryGain: \(wobbleAt(0))")
        precondition(abs(wobbleAt(0.8) - 1) < 0.06, "after recoveryZoneMs the zone must be off while the band lasts: \(wobbleAt(0.8))")
    }

    // No samples → no output; reset forgets state.
    precondition(cam.tick(now: 1000) == (0, 0))
    cam.reset()
    precondition(!cam.isStill)

    print("PASS: camera bias removal, yaw/pitch counts within 2%, signs, deadzone continuity, roll rejection, gesture mask, gesture backlash band, band-free unmask, recovery zone (attenuation, symmetry, full gain beyond the zone, plain zone at gain 0, zone window shorter than the band)")
}
