import Foundation

// Gesture detector. It is fed one GestureFrame per gyro sample, at arrival, so it sees the motion before the
// camera's jitter buffer (jitterMs) has emitted it and can veto camera output with mask/unmask.
//
// Left button: jerk down → LMB click; jerk that turns into an up-down shake → LMB held while the shaking lasts.
// Right button, wheel and pause: jerk up → RMB click; pull toward yourself → RMB latched; jerk up while latched → RMB up (bow shot, no click);
// twist about the forward axis and back → scroll ±1; case flat and still → pause (everything released) until picked up.
// A push toward the screen does nothing (free slot).
// Veto: motion with the shape of a jerk or a twist that the arming rules refuse (no calm before it: a repeated jerk, a wobble of
// the hand, or a refractory period) masks the camera and takes back its output like a gesture, but presses nothing. Otherwise the
// 30-40° rotation of an unarmed repeat goes straight to the aim.
// All gestures start from calm and share one onset path: classify by the dominant component (down → jerk down, up → jerk up,
// -forward → pull, roll → twist), then the same candidate mask, calm-exit rollback and settling (= refractory, so the hand's
// braking never counts as the opposite gesture).
// Axes: a jerk is a wrist flick, so the case moves along ITS OWN up axis (GestureFrame.axis = neutral_up, fixed in the sensor frame) and
// "down/up" (onset levels, direction share, wind-ups, shake energy, veto shapes) is measured along it. Measured against the world vertical
// the share falls to about cos(tilt) with the arm raised or lowered (live_1200: 0.06-0.54 at 47-70°, 0.93-0.99 along the case axis).
// Gravity is still removed in the world frame. Pull keeps the horizontal (world) forward: along the case-forward axis its share drops
// to 0.72 in the bow take; but a motion mostly along the case axis is a jerk, not a pull (the arm raised, a jerk up leans toward you).
//
// The camera mask of a gesture ends on rotation calm (|ω| < calm_dps for mask_rot_calm_ms, not before mask_min_ms after the onset): the
// aim follows rotation, not the linear braking of the hand. The phase (the refractory) goes on until the case has settled, so the braking
// lobe still starts no gesture and no veto. A shake re-masks. A twist chains: for twist_chain_ms after a confirmed twist the next twist
// (either direction) needs no calm arming. MINEPOINTER_GESTURE_DEBUG=1 in --replay prints why a gesture-shaped onset was refused (`trace`).
//
// All times are sensor time (seconds) except `now`, which is the Mac uptime when the frame arrived. `now` is used only
// to time the click release, so a click lasts clickHoldMs in real time even when samples arrive in a burst or stall.

enum GestureAction: Equatable {
    case lmbDown, lmbUp
    case rmbDown, rmbUp
    case scroll(Int)
    case pause, resume
}

/// Recognized gestures, for the log and a future on-screen indicator.
enum GestureName: String, Equatable {
    case jerkDown = "jerk_down"
    case shake = "shake"
    case shakeEnd = "shake_end"
    case jerkUp = "jerk_up"
    case pull = "pull"
    case bowShot = "bow_shot"       // jerk up while the RMB is latched
    case twist = "twist"            // confirmed by its return lobe; the direction is in the scroll action
    case veto = "veto"              // gesture-shaped motion that was not accepted as a gesture: camera masked and rolled back, nothing pressed
}

enum GestureEvent: Equatable {
    case action(GestureAction)
    case recognized(GestureName)
    case maskStart(Double)      // camera.mask(from:) with this sensor time
    case rollback(from: Double) // undo the camera output emitted since this sensor time (the wind-up), before the press
    case maskEnd                // camera.unmask()
}

final class GestureDetector {
    var config: Config
    var trace: ((Double, String) -> Void)?   // replay with MINEPOINTER_GESTURE_DEBUG=1: (sensor time, why a gesture-shaped onset was refused)

    private enum Phase { case idle, click, shake, twist, settling, paused }
    private var phase = Phase.idle
    private var held = false
    private var clickReleaseDue: Double?   // arrival time when a jerk click releases; nil once a shake owns the hold
    private var pressedAt = 0.0            // uptime of the last LMB press
    private var onsetTime = 0.0
    private var upBlocked = false          // a downward wind-up or a violent first frame disqualified a jerk up since calm
    private var downBlocked = false        // the same for everything else (jerk down, pull, twist): see the disarm rule below
    private var sawBrake = false           // an upward stroke came after the onset
    private var lastEnergetic = 0.0        // last time the shake energy was above the threshold
    private var settlingSince = 0.0
    private var armedBase = false          // calm for armCalmMs and nothing has fired since, so a jerk may start
    private var armed: Bool { armedBase && !downBlocked }   // jerk down, pull and twist
    private var upArmed: Bool { armedBase && !upBlocked }   // jerk up
    private var candidateSince: Double?    // the camera is masked because a jerk may be starting, nothing is pressed yet
    private var candidateMaskFrom = 0.0
    private var calmSince: Double?
    private var twistChainUntil = -Double.infinity   // after a confirmed twist the next twist needs no calm arming until this sensor time
    private var rotCalmSince: Double?      // |ω| has been below maskReleaseDps since then (the translation of a braking hand does not count)
    private var rotQuietSince: Double?     // |ω| has been below calmDps since then: the stricter release of a veto's mask
    private var vetoMask = false           // the current mask belongs to a veto
    private var maskReleasedAt = 0.0
    private var maskReleased = false       // the camera mask already ended on rotation calm; the phase (the refractory) goes on
    private var gestureStart = 0.0         // sensor time of the last gesture or veto onset
    private var calmBefore = 0.0           // length of the last calm period (trace only)
    private var dirTraced = false          // trace only: the direction-ratio refusal was reported for this activity
    private var activeSince: Double?       // the case left calm at this time
    private var minDown = 0.0              // most upward acceleration since then
    private var maxDown = 0.0              // most downward acceleration since then
    private var lastTime = -Double.infinity
    private var window: [(t: Double, v: Double)] = []   // squared vertical acceleration over shakeWindowMs
    private var windowHead = 0
    private var windowSum = 0.0
    private var rmbHeld = false
    private var rmbLatched = false         // pull latches the RMB; only a jerk up (bow shot), pause, panic or stream loss releases it
    private var rmbReleaseDue: Double?     // arrival time when a jerk-up click releases
    private var twistSign = 0              // sign of the first roll lobe: +1 = clockwise for the user
    private var twistStart = 0.0
    private var twistPeak = 0.0            // largest roll in the first lobe's direction, dps
    private var twistTheta = 0.0           // roll angle since the first lobe started, in the first lobe's direction, degrees
    private var twistThetaPeak = 0.0
    private var twistThetaPeakTime = 0.0
    private var twistLastT = 0.0
    private var lastFwdSign = 0            // direction and last time of the leading forward lobe above pullReboundG: an opposite-sign onset
    private var lastFwdTime = -Double.infinity   // within pullReboundMs of it is the hand braking or winding up (e.g. the braking of a push), not a pull
    private var omegaPeak = 0.0            // largest |ω| since the case left calm
    private var twistWindUp = 0.0
    private var twistRolledBack = false
    private var flatSince: Double?         // the case has been flat and calm since then
    private var pickedUpSince: Double?     // while paused: the case has been near neutral since then

    init(config: Config) { self.config = config }

    var isHolding: Bool { held }
    var isRmbLatched: Bool { rmbLatched }
    var isPaused: Bool { phase == .paused }

    /// Forget everything (stream loss, panic key). The caller releases the buttons and the camera mask.
    func reset() {
        phase = .idle; maskReleased = false; rotCalmSince = nil; rotQuietSince = nil; vetoMask = false; twistChainUntil = -Double.infinity; held = false; clickReleaseDue = nil; armedBase = false; candidateSince = nil; calmSince = nil; activeSince = nil; minDown = 0; maxDown = 0
        rmbHeld = false; rmbLatched = false; rmbReleaseDue = nil; flatSince = nil; pickedUpSince = nil
        lastFwdSign = 0; lastFwdTime = -Double.infinity; omegaPeak = 0
        lastTime = -Double.infinity; window.removeAll(); windowHead = 0; windowSum = 0
    }

    /// Timer call: only the click releases depend on real time.
    func tick(now: Double) -> [GestureEvent] {
        var events: [GestureEvent] = []
        releaseClickIfDue(now: now, events: &events)
        return events
    }

    func feed(_ f: GestureFrame, now: Double) -> [GestureEvent] {
        var events: [GestureEvent] = []
        let t = f.time
        if t < lastTime - 0.5 { reset() }            // sensor clock restarted: new session
        lastTime = t
        let down = f.down
        let mag = length(f.linear)

        // Calm / active tracking.
        let calm = mag < config.calmLinG && length(f.omega) < config.calmDps
        if calm {
            if calmSince == nil { calmSince = t }
            activeSince = nil; omegaPeak = 0
        } else {
            if let c = calmSince { calmBefore = t - c }
            calmSince = nil
            if activeSince == nil { activeSince = t; minDown = 0; maxDown = 0; dirTraced = false }
            minDown = min(minDown, down); maxDown = max(maxDown, down)
            omegaPeak = max(omegaPeak, length(f.omega))
        }
        if length(f.omega) < config.maskReleaseDps { if rotCalmSince == nil { rotCalmSince = t } } else { rotCalmSince = nil }
        if length(f.omega) < config.calmDps { if rotQuietSince == nil { rotQuietSince = t } } else { rotQuietSince = nil }
        pushEnergy(t: t, v: down * down)
        releaseClickIfDue(now: now, events: &events)

        // Pause: flat and calm long enough. While paused nothing is recognized, until the case is picked up.
        let tilt = tiltDegrees(f.up)
        if phase == .paused {
            if tilt > config.resumeTiltDeg { pickedUpSince = nil }
            else {
                if pickedUpSince == nil { pickedUpSince = t }
                if t - pickedUpSince! >= config.resumeMs / 1000 {
                    // Fresh calm arming before the next gesture; the camera mask is lifted by the caller on .resume.
                    phase = .idle; armedBase = false; calmSince = nil; activeSince = nil; flatSince = nil; pickedUpSince = nil
                    events.append(.action(.resume))
                }
            }
            return events
        }
        if tilt > config.pauseTiltDeg, calm {
            if flatSince == nil { flatSince = t }
            if t - flatSince! >= config.pauseStillMs / 1000 {
                phase = .paused; armedBase = false; candidateSince = nil; pickedUpSince = nil; maskReleased = false
                held = false; clickReleaseDue = nil; rmbHeld = false; rmbLatched = false; rmbReleaseDue = nil
                // The caller releases the buttons on .pause; the camera stays masked until .resume (no aim jump on pick-up).
                events += [.maskStart(t), .action(.pause)]
                return events
            }
        } else { flatSince = nil }

        // Onset classification from calm; it also runs while a twist is still unconfirmed, so a roll-led wind-up of a jerk
        // or pull (the wrist turns before the hand moves) is not lost to the twist candidate.
        var jerkLike = false, upLike = false, pullLike = false, twistLike = false
        let twistShape = abs(f.roll) >= config.twistCandidateDps && abs(f.roll) >= config.twistRollRatio * length(f.omega)
        let fwdA = f.forwardAccel
        let fwdSign = fwdA > 0 ? 1 : -1
        let reboundWindow = config.pullReboundMs / 1000
        let rebound = lastFwdSign != 0 && lastFwdSign != fwdSign && t - lastFwdTime < reboundWindow
        if abs(fwdA) >= config.pullReboundG {
            if lastFwdSign == 0 || t - lastFwdTime >= reboundWindow { lastFwdSign = fwdSign }    // a new lobe sequence starts
            if fwdSign == lastFwdSign { lastFwdTime = t }    // only the leading direction keeps the window open; the rebound cannot renew it
        }
        if phase == .idle || phase == .twist {
            if let c = calmSince, t - c >= config.armCalmMs / 1000 { armedBase = true; downBlocked = false; upBlocked = false }
            if let a = activeSince {
                // Each direction has its own wind-up rule, so the lobe of one jerk never disqualifies the mirrored one.
                if minDown < -config.jerkWindupMaxG || down > config.jerkMaxOnsetG {
                    if trace != nil, !downBlocked { note(t, "jerk down/pull/twist blocked: \(minDown < -config.jerkWindupMaxG ? "upward wind-up \(f2(-minDown)) g" : "first frame \(f2(down)) g too violent")", f, tilt) }
                    downBlocked = true
                }
                if maxDown > config.jerkUpWindupMaxG || -down > config.jerkMaxOnsetG {
                    if trace != nil, !upBlocked { note(t, "jerk up blocked: \(maxDown > config.jerkUpWindupMaxG ? "downward wind-up \(f2(maxDown)) g" : "first frame \(f2(-down)) g too violent")", f, tilt) }
                    upBlocked = true
                }
                // A jerk ramps up along the vertical from its first strong frame; a strong off-axis frame first is a hand movement
                // (the end of a shake, a regrip), so a later vertical-looking frame is not a jerk up.
                if mag >= config.jerkUpOnsetG, -down < config.jerkUpDirectionRatio * mag {
                    if trace != nil, !upBlocked { note(t, "jerk up blocked: off-axis frame, up share \(f2(-down / mag)) < \(config.jerkUpDirectionRatio)", f, tilt) }
                    upBlocked = true
                }
                if trace != nil, armedBase, !dirTraced, down >= config.jerkOnsetG, down < config.jerkDirectionRatio * mag {
                    dirTraced = true; note(t, "jerk down refused: down share \(f2(down / mag)) < \(config.jerkDirectionRatio)", f, tilt)
                }
                if t - a > config.onsetWindowMs / 1000 {
                    if trace != nil, armedBase { note(t, "disarmed: no onset level within onset_window_ms", f, tilt) }
                    armedBase = false
                }
            }
            let live = armed && activeSince != nil
            let upLive = upArmed && activeSince != nil
            let chained = activeSince != nil && t < twistChainUntil   // a quick repeat of a twist: calm arming is skipped
            twistLike = (live || chained) && twistShape
                && mag < (live ? config.calmLinG : config.twistChainLinG)   // a real twist starts with almost no translation; a jerk's wind-up already has some. A quick repeat has more: 0.2-0.6 g in live_1104
            jerkLike = live && !twistShape && down >= config.jerkDirectionRatio * mag    // a roll-led frame is a twist even when its translation points along the case axis (twist_ccw, first rep: 598 dps, down share 0.90); jerks fire at roll up to 119 dps
            upLike = upLive && !twistShape && -down >= config.jerkUpDirectionRatio * mag
            pullLike = live && !rebound && fwdA < 0 && -fwdA >= config.pullDirectionRatio * mag && omegaPeak < config.pullMaxDps
                && abs(down) < config.jerkDirectionRatio * mag    // mostly along the case axis it is a jerk: with the arm raised the case axis leans toward you, so a jerk up there has a toward-yourself part (the world share) of sin(tilt)
        }
        /// Jerk or pull reaches its onset level: press, mask, rollback. Returns false if nothing fired.
        func fireOnset() -> Bool {
            if jerkLike, down >= config.jerkOnsetG {
                armedBase = false
                if trace != nil { note(t, "jerk down fired, down share \(f2(down / mag))", f, tilt) }
                phase = .click; onsetTime = t; sawBrake = false
                held = true; pressedAt = now; clickReleaseDue = now + config.clickHoldMs / 1000
                startGesture(t, events: &events)
                events += [.recognized(.jerkDown), .action(.lmbDown)]
                return true
            }
            if upLike, -down >= config.jerkUpOnsetG {
                armedBase = false
                if trace != nil { note(t, "jerk up/bow shot fired, up share \(f2(-down / mag))", f, tilt) }
                startGesture(t, events: &events)
                if rmbLatched {                      // bow shot: jerk up while the RMB is latched, no click
                    rmbLatched = false; rmbHeld = false
                    events += [.recognized(.bowShot), .action(.rmbUp)]
                } else {
                    rmbHeld = true; rmbReleaseDue = now + config.clickHoldMs / 1000
                    events += [.recognized(.jerkUp), .action(.rmbDown)]
                }
                enterSettling(t, delay: config.pullBrakeMs / 1000)   // refractory: the downward braking lobe is not a jerk down
                return true
            }
            guard pullLike, -fwdA >= config.pullOnsetG else { return false }
            armedBase = false
            startGesture(t, events: &events)
            if rmbLatched {
                events.append(.recognized(.pull))    // already latched: recognized, nothing to do
            } else {
                rmbLatched = true; rmbHeld = true; rmbReleaseDue = nil
                events += [.recognized(.pull), .action(.rmbDown)]
            }
            enterSettling(t, delay: config.pullBrakeMs / 1000)   // refractory: the braking is not a jerk or push
            return true
        }

        switch phase {
        case .idle:
            // The same shape tests as the real detectors (jerk: vertical share and onset level, twist: roll share and candidate
            // level), without the arming and the calm-start requirement of twistLike.
            let vetoShape = (!armed && down >= config.jerkOnsetG && down >= config.jerkDirectionRatio * mag)
                || (!upArmed && -down >= config.jerkUpOnsetG && -down >= config.jerkUpDirectionRatio * mag)
                || (!armed && twistShape)
            if fireOnset() {
            } else if twistLike {
                // First roll lobe: mask the camera now; the gesture is only confirmed by the return lobe (phase .twist).
                phase = .twist; twistSign = f.roll > 0 ? 1 : -1; twistStart = t; twistPeak = 0; twistRolledBack = false
                twistTheta = 0; twistThetaPeak = 0; twistThetaPeakTime = t; twistLastT = t
                twistWindUp = max(activeSince!, t - config.rollbackMaxMs / 1000)
                if candidateSince == nil { events.append(.maskStart(min(twistWindUp, t - config.gesturePreMs / 1000))) }
                candidateSince = nil; maskReleased = false; vetoMask = false
            } else if vetoShape, activeSince != nil {
                armedBase = false
                if trace != nil { note(t, "VETO (armed \(armed) upArmed \(upArmed) armedBase \(armedBase))", f, tilt) }
                startGesture(t, events: &events)
                vetoMask = true
                events.append(.recognized(.veto))
                enterSettling(t, delay: config.pullBrakeMs / 1000)   // settles like a gesture: calm ends the mask, the timeout at the latest (after the braking)
            } else if jerkLike || upLike || pullLike, candidateSince == nil,
                      (jerkLike ? down : upLike ? -down : -fwdA) >= config.maskCandidateG {
                // The ramp of a jerk or pull: mask the camera now, 20-60 ms before the press level, because the jitter buffer
                // has only 60 ms of output left to veto. Nothing is pressed until the onset level.
                candidateSince = t; maskReleased = false; vetoMask = false
                candidateMaskFrom = t - config.gesturePreMs / 1000
                events.append(.maskStart(candidateMaskFrom))
            } else if let c = candidateSince, (!armed && !upArmed) || t - c > config.candidateMs / 1000 {
                candidateSince = nil                 // it was not a gesture: the camera resumes
                events.append(.maskEnd)
            }

        case .click:
            releaseMaskIfRotationCalm(t, events: &events)    // the aim does not wait for the shake decision; a shake re-masks below
            if down <= -config.shakeBrakeG { sawBrake = true }
            if sawBrake, down >= config.shakeStrokeG {
                phase = .shake; lastEnergetic = t; clickReleaseDue = nil
                if maskReleased {                    // the shake moves the case again: mask it and take back what leaked since the release
                    let from = max(maskReleasedAt, t - config.rollbackMaxMs / 1000)
                    maskReleased = false
                    events += [.maskStart(min(from, t - config.gesturePreMs / 1000)), .rollback(from: from)]
                }
                if !held { held = true; pressedAt = now; events.append(.action(.lmbDown)) }
                events.append(.recognized(.shake))
            } else if t - onsetTime > config.shakeJoinMs / 1000 {
                enterSettling(t)
            } else {
                finishIfSettled(t, events: &events)
            }

        case .shake:
            if energy() >= config.shakeRmsG {
                lastEnergetic = t
            } else if t - lastEnergetic >= config.shakeHangoverMs / 1000 {
                held = false
                events += [.action(.lmbUp), .recognized(.shakeEnd)]
                enterSettling(t)
            }

        case .twist:
            if twistThetaPeak < config.twistMinDeg || twistPeak < config.twistPeakDps, fireOnset() { break }   // a jerk or pull after all
            let r = Double(twistSign) * f.roll
            twistTheta += r * min(t - twistLastT, 0.05); twistLastT = t
            twistPeak = max(twistPeak, r)
            if twistTheta > twistThetaPeak { twistThetaPeak = twistTheta; twistThetaPeakTime = t }
            let peaked = twistPeak >= config.twistPeakDps && twistThetaPeak >= config.twistMinDeg
            if peaked, !twistRolledBack {
                twistRolledBack = true; armedBase = false    // a real twist: take back the leakage since calm exit, as for a click
                events.append(.rollback(from: twistWindUp))
            }
            if peaked, twistTheta <= (1 - config.twistReturnFraction) * twistThetaPeak {
                events += [.recognized(.twist), .action(.scroll(twistSign))]
                gestureStart = t; twistChainUntil = t + config.twistChainMs / 1000
                enterSettling(t)                         // the return lobe's own braking must not scroll again
            } else if t - (peaked ? twistThetaPeakTime : twistStart) > (peaked ? config.twistReturnMs : config.onsetWindowMs) / 1000 {
                phase = .idle; events.append(.maskEnd)   // no return (or never strong enough): nothing happened, the camera resumes
            }

        case .paused:
            break                                        // handled above

        case .settling:
            releaseMaskIfRotationCalm(t, events: &events)
            finishIfSettled(t, events: &events)
            if phase == .settling, t - settlingSince >= config.maskTimeoutMs / 1000 {
                phase = .idle; endMask(&events)
            }
        }
        return events
    }

    // MARK: Helpers

    private func releaseClickIfDue(now: Double, events: inout [GestureEvent]) {
        // Independent of the phase: the case may settle before the click is due, and the button must still come up.
        if let due = clickReleaseDue, held, now >= due {
            held = false; clickReleaseDue = nil
            events.append(.action(.lmbUp))
        }
        if let due = rmbReleaseDue, rmbHeld, !rmbLatched, now >= due {
            rmbHeld = false; rmbReleaseDue = nil
            events.append(.action(.rmbUp))
        }
    }

    /// Onset of a press-type gesture (jerk down, jerk up, pull). Everything since the case left calm is wind-up of this gesture:
    /// mask what is still queued and take back what is already out, so the press lands where the aim was when the hand was calm.
    private func startGesture(_ t: Double, events: inout [GestureEvent]) {
        let windUp = max(activeSince!, t - config.rollbackMaxMs / 1000)
        let maskFrom = min(windUp, t - config.gesturePreMs / 1000)
        gestureStart = t; maskReleased = false; vetoMask = false; twistChainUntil = -Double.infinity
        if candidateSince == nil || maskFrom < candidateMaskFrom { events.append(.maskStart(maskFrom)) }
        candidateSince = nil
        events.append(.rollback(from: windUp))
    }

    private func enterSettling(_ t: Double, delay: Double = 0) {
        phase = .settling; settlingSince = t + delay     // the mask timeout counts from settlingSince, so `delay` extends it
    }

    /// The gesture is over once the case has been calm for settleMs: the camera resumes.
    private func finishIfSettled(_ t: Double, events: inout [GestureEvent]) {
        guard let c = calmSince, t - c >= config.settleMs / 1000 else { return }
        phase = .idle
        endMask(&events)
    }

    private func endMask(_ events: inout [GestureEvent]) {
        if !maskReleased { events.append(.maskEnd) }
        maskReleased = false
    }

    /// The camera follows the rotation of the case, not the linear acceleration of the braking hand: once the case has stopped
    /// turning (|ω| < maskReleaseDps for maskRotCalmMs, and not before maskMinMs after the onset) the camera mask ends. The phase goes on
    /// as the refractory, so the braking lobe still starts no gesture and no veto; a shake re-masks.
    private func releaseMaskIfRotationCalm(_ t: Double, events: inout [GestureEvent]) {
        guard !maskReleased, let r = vetoMask ? rotQuietSince : rotCalmSince, t - r >= config.maskRotCalmMs / 1000, t - gestureStart >= config.maskMinMs / 1000 else { return }
        maskReleased = true; maskReleasedAt = t
        events.append(.maskEnd)
    }

    private func f2(_ v: Double) -> String { String(format: "%.2f", v) }

    private func note(_ t: Double, _ why: String, _ f: GestureFrame, _ tilt: Double) {
        let mag = max(length(f.linear), 1e-9)
        trace?(t, String(format: "%@ | case-axis down %.2f g (share %+.2f), world fwd %.2f g (share %+.2f), right %.2f g, |a_lin| %.2f g, |w| %.0f dps (roll %.0f), tilt %.0f deg, calm before %.0f ms", why, f.down, f.down / mag, f.forwardAccel, f.forwardAccel / mag, f.rightAccel, length(f.linear), length(f.omega), f.roll, tilt, calmBefore * 1000))
    }

    private func tiltDegrees(_ up: SIMD3<Double>) -> Double {
        let n = SIMD3<Double>(config.neutralUp[0], config.neutralUp[1], config.neutralUp[2])
        return acos(min(1, max(-1, dot(up, n) / length(n)))) * 180 / Double.pi
    }

    private func pushEnergy(t: Double, v: Double) {
        window.append((t, v)); windowSum += v
        while windowHead < window.count, window[windowHead].t < t - config.shakeWindowMs / 1000 {
            windowSum -= window[windowHead].v; windowHead += 1
        }
        if windowHead > 256 { window.removeFirst(windowHead); windowHead = 0 }
    }

    /// RMS of the vertical acceleration over the window, in g.
    private func energy() -> Double {
        let n = window.count - windowHead
        return n > 0 ? (max(0, windowSum) / Double(n)).squareRoot() : 0
    }
}

// MARK: Self-test

private let up = SIMD3<Double>(0, -1, 0)   // ~20° from config.neutralUp (0.02, -0.94, -0.35)
private let fwd = SIMD3<Double>(0, 0, 1)

/// Synthetic 200 Hz frames. `down(t)` is the vertical acceleration (g, positive downward), `side(t)` a horizontal one.
private struct Rig {
    var detector: GestureDetector
    var t = 0.0
    var events: [(t: Double, e: GestureEvent)] = []
    var arrivalLag = 0.002
    var upVec = up                       // the world vertical in the sensor frame (gravity); (1, 0, 0) is the case lying flat
    var axis = up                        // the case-fixed up axis the jerks move along

    init(_ config: Config) { detector = GestureDetector(config: config) }

    mutating func run(seconds: Double, down: (Double) -> Double, side: (Double) -> Double = { _ in 0 }) {
        drive(seconds: seconds, down: down, side: side)
    }

    /// `push(t)` is forward acceleration (g, positive toward the screen), `roll(t)` the rate about forward (dps, positive = clockwise).
    mutating func drive(seconds: Double, down: (Double) -> Double = { _ in 0 }, side: (Double) -> Double = { _ in 0 },
                        push: (Double) -> Double = { _ in 0 }, roll: (Double) -> Double = { _ in 0 }) {
        let t0 = t, dt = 0.005
        while t < t0 + seconds {
            let local = t - t0
            let fw = (fwd - dot(fwd, upVec) * upVec) / length(fwd - dot(fwd, upVec) * upVec)   // horizontal forward, as the camera derives it
            let lin = -down(local) * axis + side(local) * cross(fw, upVec) + push(local) * fw
            let frame = GestureFrame(time: t, up: upVec, axis: axis, forward: fw, right: cross(fw, upVec), linear: lin, omega: roll(local) * fw)
            for e in detector.feed(frame, now: t + arrivalLag) { events.append((t, e)) }
            for e in detector.tick(now: t + arrivalLag) { events.append((t, e)) }
            t += dt
        }
    }

    func times(_ action: GestureAction) -> [Double] { events.filter { $0.e == .action(action) }.map { $0.t } }
    func times(_ name: GestureName) -> [Double] { events.filter { $0.e == .recognized(name) }.map { $0.t } }
    func count(_ e: GestureEvent) -> Int { events.filter { $0.e == e }.count }
}

/// One half-sine lobe of `peak` g lasting `length` seconds starting at `start`.
private func lobe(_ t: Double, start: Double, length: Double, peak: Double) -> Double {
    guard t >= start, t < start + length else { return 0 }
    return peak * sin(Double.pi * (t - start) / length)
}

func gestureSelfTest() {
    let config = Config()
    let calmBefore = 0.5

    // Single jerk: +1.7 g for 120 ms, then an upward brake of 2 g, then calm. A recovery bump of 0.8 g follows.
    var rig = Rig(config)
    rig.run(seconds: calmBefore) { _ in 0 }
    let jerkStart = rig.t
    rig.run(seconds: 1.5) { t in
        lobe(t, start: 0, length: 0.12, peak: 1.7) - lobe(t, start: 0.12, length: 0.12, peak: 2.0) + lobe(t, start: 0.3, length: 0.2, peak: 0.8)
    }
    let presses = rig.times(.lmbDown), releases = rig.times(.lmbUp)
    precondition(presses.count == 1, "single jerk: \(presses.count) presses")
    // Onset: down reaches 0.7 g after 1.7·sin(π t/0.12) = 0.7, t ≈ 16 ms. The press must come within a frame or two.
    precondition(presses[0] - jerkStart < 0.03, "press not at onset: \((presses[0] - jerkStart) * 1000) ms")
    precondition(rig.times(.jerkDown).count == 1)
    precondition(releases.count == 1, "click releases: \(releases.count)")
    let held = releases[0] - presses[0]
    precondition(abs(held - config.clickHoldMs / 1000) < 0.012, "click held \(held * 1000) ms")
    // The mask starts before the onset and ends once, after the case has settled.
    guard case .maskStart(let from)? = rig.events.first(where: { if case .maskStart = $0.e { return true } else { return false } })?.e else {
        preconditionFailure("no mask start")
    }
    // It starts at the candidate level (0.4 g, a few ms before the press at 0.7 g), once.
    precondition(from < presses[0] - config.gesturePreMs / 1000 + 0.001 && from > presses[0] - config.gesturePreMs / 1000 - 0.03)
    precondition(rig.events.filter { if case .maskStart = $0.e { return true } else { return false } }.count == 1)
    precondition(rig.count(.maskEnd) == 1)
    // A jerk down gives the camera back right after the click (mask_min_ms), not after the shake decision (shake_join_ms) or the settle.
    let jerkMaskEnd = rig.events.first { $0.e == .maskEnd }!.t - presses[0]
    precondition(jerkMaskEnd < 0.15 && jerkMaskEnd < config.shakeJoinMs / 1000 / 2, "jerk down mask ends \(jerkMaskEnd * 1000) ms after the press")
    // The braking (upward) lobe and the recovery bump started no second gesture.
    precondition(rig.count(.recognized(.shake)) == 0)
    // An armed jerk is a gesture, never a veto.
    precondition(rig.times(.veto).isEmpty, "armed jerk was vetoed")

    // An upward lobe from calm (a jerk up, or the braking of a jerk down arriving from calm) never presses LMB.
    rig = Rig(config)
    rig.run(seconds: calmBefore) { _ in 0 }
    rig.run(seconds: 1) { t in -lobe(t, start: 0, length: 0.15, peak: 3) }
    precondition(rig.times(.lmbDown).isEmpty, "upward lobe pressed LMB")

    // A bump of 0.95 g right after the brake (above the onset level, below a shake stroke) is refractory; after calm a new jerk works.
    rig = Rig(config)
    rig.run(seconds: calmBefore) { _ in 0 }
    rig.run(seconds: 0.6) { t in lobe(t, start: 0, length: 0.12, peak: 1.7) - lobe(t, start: 0.12, length: 0.12, peak: 2.0) + lobe(t, start: 0.3, length: 0.2, peak: 0.95) }
    precondition(rig.times(.lmbDown).count == 1, "refractory failed")
    rig.run(seconds: 1) { _ in 0 }
    rig.run(seconds: 0.5) { t in lobe(t, start: 0, length: 0.12, peak: 1.7) }
    precondition(rig.times(.lmbDown).count == 2, "no second click after calm")

    // A weak bump (0.55 g) masks the camera as a candidate, presses nothing, and gives the camera back.
    rig = Rig(config)
    rig.run(seconds: calmBefore) { _ in 0 }
    rig.run(seconds: 1) { t in lobe(t, start: 0, length: 0.2, peak: 0.55) }
    precondition(rig.times(.lmbDown).isEmpty, "weak bump pressed")
    precondition(rig.times(.veto).isEmpty, "weak bump (below the jerk level) was vetoed")
    precondition(rig.count(.maskEnd) == 1 && rig.events.filter { if case .maskStart = $0.e { return true } else { return false } }.count == 1)

    // Horizontal acceleration is not a jerk (push toward the screen, 1.4 g).
    rig = Rig(config)
    rig.run(seconds: calmBefore) { _ in 0 }
    rig.run(seconds: 1, down: { _ in 0 }, side: { t in lobe(t, start: 0, length: 0.12, peak: 1.4) })
    precondition(rig.times(.lmbDown).isEmpty, "sideways acceleration pressed")

    // Shake: jerk, then 3 Hz up-down strokes for 3 s (weak downward half, strong upward half), then calm.
    // Gaps between strokes stay under the hangover, so once the shake is confirmed the button never comes up until it ends.
    rig = Rig(config)
    rig.run(seconds: calmBefore) { _ in 0 }
    let shakeStart = rig.t
    let shakeSeconds = 3.0
    rig.run(seconds: shakeSeconds) { t in 3.0 * sin(2 * Double.pi * 3 * t) * (sin(2 * Double.pi * 3 * t) > 0 ? 0.7 : 1) }
    rig.run(seconds: 2) { _ in 0 }
    let shakeFirst = rig.times(.shake)
    precondition(shakeFirst.count == 1, "shake recognized \(shakeFirst.count) times")
    let shakeDown = rig.times(.lmbDown), shakeUp = rig.times(.lmbUp)
    // clickHoldMs (150) ends before the second stroke (creative must not break two blocks), so a shake is the click,
    // then one continuous hold from its first stroke until the shaking ends: two presses, never a release mid-shake.
    precondition(shakeDown.count == 2 && shakeUp.count == 2, "presses \(shakeDown.count), releases \(shakeUp.count)")
    precondition(shakeUp[0] - shakeStart < config.clickHoldMs / 1000 + 0.05, "click release late")
    precondition(shakeDown[1] - shakeStart < 0.5, "shake hold started late at \(shakeDown[1] - shakeStart)")
    let shakeEnd = shakeStart + shakeSeconds
    precondition(shakeUp[1] > shakeEnd - 0.1, "released during the shake at \(shakeUp[1] - shakeStart)")
    precondition(shakeUp[1] < shakeEnd + config.shakeWindowMs / 1000 + config.shakeHangoverMs / 1000 + 0.1,
                 "released late at \(shakeUp[1] - shakeEnd) s after the shake")
    precondition(rig.times(.shakeEnd).count == 1)
    // The jerk released the camera right after the click, the shake masked it again: every mask start has its end, and the camera is free at the end.
    let shakeMasks = rig.events.filter { if case .maskStart = $0.e { return true } else { return false } }.count
    precondition(shakeMasks == 2 && rig.count(.maskEnd) == 2, "shake masks: \(shakeMasks) starts, \(rig.count(.maskEnd)) ends, expected 2 and 2 (click, then the shake re-masks)")

    // Shake energy hangover: a 150 ms pause in the strokes (shorter than the hangover) does not release.
    rig = Rig(config)
    rig.run(seconds: calmBefore) { _ in 0 }
    rig.run(seconds: 1.2) { t in 3.0 * sin(2 * Double.pi * 3 * t) }
    rig.run(seconds: 0.2) { _ in 0 }
    let before = rig.times(.lmbUp).count
    rig.run(seconds: 1.0) { t in 3.0 * sin(2 * Double.pi * 3 * t) }
    precondition(rig.times(.lmbUp).count == before, "button released in a pause shorter than the hangover")
    precondition(rig.detector.isHolding)

    // Not armed without calm: a jerk-like lobe on top of constant motion (|a_lin| 0.5 g) is ignored.
    rig = Rig(config)
    rig.run(seconds: 1, down: { _ in 0 }, side: { _ in 0.5 })
    rig.run(seconds: 0.5, down: { t in lobe(t, start: 0, length: 0.12, peak: 1.7) }, side: { _ in 0.5 })
    precondition(rig.times(.lmbDown).isEmpty, "jerk without calm pressed")
    precondition(rig.times(.veto).count == 1, "jerk without calm: \(rig.times(.veto).count) vetoes, expected 1")
    precondition(rig.count(.maskEnd) == 0 || rig.count(.maskEnd) == 1)

    // The same for an unarmed twist-shaped roll: vetoed, no scroll, nothing pressed.
    rig = Rig(config)
    rig.drive(seconds: 1, side: { _ in 0.5 })
    rig.drive(seconds: 0.6, side: { _ in 0.5 }, roll: { t in 600 * lobe(t, start: 0, length: 0.12, peak: 1) })
    precondition(rig.times(.veto).count == 1 && rig.events.filter { if case .action = $0.e { return true } else { return false } }.isEmpty,
                 "unarmed twist: \(rig.times(.veto).count) vetoes")

    // Reset releases nothing by itself but forgets the hold.
    rig = Rig(config)
    rig.run(seconds: 1, down: { _ in 0 }, side: { _ in 0.5 })
    rig.run(seconds: 0.5, down: { t in lobe(t, start: 0, length: 0.12, peak: 1.7) }, side: { _ in 0.5 })
    rig.detector.reset()
    precondition(!rig.detector.isHolding)

    // Rollback: a wind-up rotation (60 dps yaw for 0.15 s, leaves calm) and then a jerk. The camera output of the
    // wind-up is taken back at the press, so the net aim change over the whole gesture is about zero.
    do {
        let cam = Camera(config: config)
        let det = GestureDetector(config: config)
        let g = SIMD3<Double>(0.02, -0.94, -0.35), gUp = g / length(g)
        let bias = SIMD3<Double>(0.24, 0.96, 0.26)
        var t = 0.0, nextTick = 0.0, net = SIMD2<Double>(0, 0), peak = 0.0
        var pending = SIMD2<Double>(0, 0), presses = 0
        let end = 3.0 + 3.0
        while t < end {
            let local = t - 3.0
            let windUp = local >= 0 && local < 0.15
            let down = local >= 0.1 ? lobe(local, start: 0.1, length: 0.12, peak: 1.7) - lobe(local, start: 0.22, length: 0.12, peak: 2.0) : 0
            let a = g - down * gUp
            let w = bias + (windUp ? 60 * gUp : SIMD3(0, 0, 0))
            let recv = t + 0.002
            cam.feed(MotionSample(kind: .accel, sensorTime: t, receivedUptime: recv, x: -a.x, y: -a.y, z: -a.z))   // sensor reports accel negated
            if let frame = cam.feed(MotionSample(kind: .gyro, sensorTime: t, receivedUptime: recv, x: w.x, y: w.y, z: w.z)) {
                for e in det.feed(frame, now: recv) {
                    switch e {
                    case .maskStart(let from): cam.mask(from: from)
                    case .maskEnd: cam.unmask()
                    case .rollback(let from): let r = cam.rollback(from: from); pending += SIMD2(Double(r.dx), Double(r.dy))
                    case .action(.lmbDown): presses += 1
                    default: break
                    }
                }
            }
            while nextTick <= recv {
                let c = cam.tick(now: nextTick)
                net += SIMD2(Double(c.dx), Double(c.dy)) + pending; pending = SIMD2(0, 0)
                peak = max(peak, abs(net.x) + abs(net.y))
                nextTick += 1 / 240
            }
            t += 0.005
        }
        precondition(presses == 1, "rollback test pressed \(presses) times")
        precondition(peak > 50, "wind-up never reached the output (peak \(peak) counts), test is void")
        precondition(abs(net.x) <= 3 && abs(net.y) <= 3, "net aim change \(net) counts, expected about 0")
    }

    // Veto: a repeat jerk with no calm since the first one (the hand keeps wobbling) is gesture-shaped but unarmed. It must not
    // press, and the camera must come out where it was: the 36° the case rotates during the repeat never reaches the aim.
    do {
        let g = SIMD3<Double>(0.02, -0.94, -0.35), gUp = g / length(g)
        let bias = SIMD3<Double>(0.24, 0.96, 0.26)
        func run(vetoes enabled: Bool) -> (net: SIMD2<Double>, presses: Int, vetoes: Int, peak: Double) {
            let cam = Camera(config: config)
            let det = GestureDetector(config: config)
            var t = 0.0, nextTick = 0.0, net = SIMD2<Double>(0, 0), peak = 0.0
            var pending = SIMD2<Double>(0, 0), presses = 0, vetoes = 0
            while t < 3.0 + 4.0 {
                let local = t - 3.0
                // first jerk down at 0.1 s (its mask lasts until about 1.1 s), a 100 dps wobble from 0.12 s to 1.45 s (never calm: the mask ends on rotation calm, so the wobble has to start with the jerk, as the hand's does),
                // the repeat jerk down at 1.5 s with 600 dps for 60 ms
                var down = 0.0, rate = 0.0
                if local >= 0.1 { down += lobe(local, start: 0.1, length: 0.12, peak: 1.7) - lobe(local, start: 0.22, length: 0.12, peak: 2.0) }
                if local >= 0.12, local < 1.45 { rate += 100 * sin(2 * Double.pi * 1.5 * (local - 0.12)) }
                if local >= 1.5 { down += lobe(local, start: 1.5, length: 0.12, peak: 1.7) - lobe(local, start: 1.62, length: 0.12, peak: 2.0) }
                if local >= 1.5, local < 1.56 { rate += 600 }
                let a = g - down * gUp, w = bias + rate * gUp
                let recv = t + 0.002
                cam.feed(MotionSample(kind: .accel, sensorTime: t, receivedUptime: recv, x: -a.x, y: -a.y, z: -a.z))
                if let frame = cam.feed(MotionSample(kind: .gyro, sensorTime: t, receivedUptime: recv, x: w.x, y: w.y, z: w.z)), enabled {
                    for e in det.feed(frame, now: recv) {
                        switch e {
                        case .maskStart(let from): cam.mask(from: from)
                        case .maskEnd: cam.unmask()
                        case .rollback(let from): let r = cam.rollback(from: from); pending += SIMD2(Double(r.dx), Double(r.dy))
                        case .action(.lmbDown): presses += 1
                        case .recognized(.veto): vetoes += 1
                        default: break
                        }
                    }
                }
                while nextTick <= recv {
                    let c = cam.tick(now: nextTick)
                    net += SIMD2(Double(c.dx), Double(c.dy)) + pending; pending = SIMD2(0, 0)
                    peak = max(peak, abs(net.x) + abs(net.y))
                    nextTick += 1 / 240
                }
                t += 0.005
            }
            return (net, presses, vetoes, peak)
        }
        let free = run(vetoes: false), vetoed = run(vetoes: true)
        let rotation = 36 * config.gain * config.countsPerDegree
        precondition(abs(free.net.x) + abs(free.net.y) > 0.8 * rotation, "veto test is void: the repeat moved the aim by \(free.net) counts only")
        precondition(vetoed.presses == 1, "repeat jerk: \(vetoed.presses) presses, expected only the first")
        precondition(vetoed.vetoes == 1, "repeat jerk: \(vetoed.vetoes) vetoes, expected 1")
        precondition(abs(vetoed.net.x) < 0.05 * rotation && abs(vetoed.net.y) < 0.05 * rotation,
                     "vetoed repeat moved the aim by \(vetoed.net) counts (free: \(free.net))")
    }

    // A jerk that settles before click_hold_ms still releases the button (it used to stay held).
    var quick = Rig(config)
    quick.run(seconds: calmBefore) { _ in 0 }
    quick.run(seconds: 1.0) { t in lobe(t, start: 0, length: 0.06, peak: 1.2) - lobe(t, start: 0.06, length: 0.06, peak: 1.0) }
    precondition(quick.times(.lmbDown).count == 1 && quick.times(.lmbUp).count == 1,
                 "quick jerk: \(quick.times(.lmbDown).count) presses, \(quick.times(.lmbUp).count) releases")

    // MARK: Right button, wheel and pause

    func has(_ rig: Rig, _ pred: (GestureEvent) -> Bool) -> Int { rig.events.filter { pred($0.e) }.count }
    func isMaskStart(_ e: GestureEvent) -> Bool { if case .maskStart = e { return true } else { return false } }
    func isRollback(_ e: GestureEvent) -> Bool { if case .rollback = e { return true } else { return false } }
    func isScroll(_ e: GestureEvent) -> Bool { if case .action(.scroll) = e { return true } else { return false } }
    /// A push: +1.4 g toward the screen for 120 ms, then the hand brakes with -1.6 g. A pull is the mirror image.
    func pushLobes(_ t: Double) -> Double { lobe(t, start: 0, length: 0.12, peak: 1.4) - lobe(t, start: 0.12, length: 0.12, peak: 1.6) }
    func pullLobes(_ t: Double) -> Double { -lobe(t, start: 0, length: 0.12, peak: 1.2) + lobe(t, start: 0.12, length: 0.12, peak: 1.4) }
    /// A jerk up is the mirror of a jerk down (`down` is positive downward): 1.7 g up, then a 2 g downward brake.
    func jerkUpLobes(_ t: Double) -> Double { -lobe(t, start: 0, length: 0.12, peak: 1.7) + lobe(t, start: 0.12, length: 0.12, peak: 2.0) }
    /// A twist: first lobe of `peak` dps (45° about forward at 600 dps), then the same angle back.
    func twistLobes(_ t: Double, sign: Double) -> Double { sign * (lobe(t, start: 0, length: 0.12, peak: 600) - lobe(t, start: 0.12, length: 0.2, peak: 360)) }

    // Jerk up: RMB down at the onset, up after click_hold_ms in real time, once; the downward braking lobe is no jerk down.
    rig = Rig(config)
    rig.drive(seconds: calmBefore)
    let upStart = rig.t
    rig.drive(seconds: 1.5, down: jerkUpLobes)
    precondition(rig.times(.rmbDown).count == 1 && rig.times(.rmbUp).count == 1, "jerk up: \(rig.times(.rmbDown).count) downs, \(rig.times(.rmbUp).count) ups")
    precondition(rig.times(.rmbDown)[0] - upStart < 0.06, "jerk up press late: \((rig.times(.rmbDown)[0] - upStart) * 1000) ms")
    let rmbHeld = rig.times(.rmbUp)[0] - rig.times(.rmbDown)[0]
    precondition(abs(rmbHeld - config.clickHoldMs / 1000) < 0.012, "jerk up click held \(rmbHeld * 1000) ms")
    precondition(rig.times(.jerkUp).count == 1 && rig.times(.pull).isEmpty && rig.times(.lmbDown).isEmpty, "jerk up brake or pull logic misfired")
    precondition(has(rig, isMaskStart) >= 1 && rig.count(.maskEnd) == 1, "jerk up mask: \(has(rig, isMaskStart)) starts, \(rig.count(.maskEnd)) ends")
    precondition(!rig.detector.isRmbLatched)
    // After calm a second jerk up clicks again; the refractory only covers the braking.
    rig.drive(seconds: 1)
    rig.drive(seconds: 0.6, down: jerkUpLobes)
    precondition(rig.times(.rmbDown).count == 2, "no second jerk up after calm")

    // Jerk down: its upward braking lobe is no jerk up (no RMB), and a jerk down after an upward wind-up (0.5 g, below
    // jerk_up_onset_g) is still only an LMB click.
    rig = Rig(config)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 1.5, down: { t in lobe(t, start: 0, length: 0.12, peak: 1.7) - lobe(t, start: 0.12, length: 0.12, peak: 2.0) })
    precondition(rig.times(.lmbDown).count == 1 && rig.times(.rmbDown).isEmpty, "jerk down brake gave RMB")
    rig = Rig(config)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 1.5, down: { t in -lobe(t, start: 0, length: 0.1, peak: 0.5) + lobe(t, start: 0.1, length: 0.12, peak: 1.7) - lobe(t, start: 0.22, length: 0.12, peak: 2.0) })
    precondition(rig.times(.lmbDown).count == 1 && rig.times(.rmbDown).isEmpty && rig.times(.jerkUp).isEmpty, "jerk down with an upward wind-up: \(rig.times(.lmbDown).count) LMB, \(rig.times(.rmbDown).count) RMB")
    // The mirror: a jerk up after a downward wind-up of 0.5 g is only an RMB click.
    rig = Rig(config)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 1.5, down: { t in lobe(t, start: 0, length: 0.1, peak: 0.5) - lobe(t, start: 0.1, length: 0.12, peak: 1.7) + lobe(t, start: 0.22, length: 0.12, peak: 2.0) })
    precondition(rig.times(.rmbDown).count == 1 && rig.times(.lmbDown).isEmpty, "jerk up with a downward wind-up: \(rig.times(.rmbDown).count) RMB, \(rig.times(.lmbDown).count) LMB")

    // A push toward the screen does nothing, and its braking lobe is not a pull (it falls into the rebound guard).
    rig = Rig(config)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 1.5, push: pushLobes)
    precondition(rig.events.filter { if case .action = $0.e { return true } else { return false } }.isEmpty && rig.times(.pull).isEmpty, "push did something")

    // A soft pull-direction brake after a soft push (0.45 g, below the onset, 0.9 g braking) is a rebound, not a pull.
    rig = Rig(config)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 1, push: { t in lobe(t, start: 0, length: 0.3, peak: 0.45) - lobe(t, start: 0.3, length: 0.15, peak: 0.9) })
    precondition(rig.times(.rmbDown).isEmpty && rig.times(.pull).isEmpty, "rebound of a soft push became a pull")

    // Pull: RMB latched at the onset and stays down; the braking lobe is not a jerk up (it would release).
    rig = Rig(config)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 3, push: pullLobes)
    precondition(rig.times(.rmbDown).count == 1 && rig.times(.rmbUp).isEmpty, "pull: \(rig.times(.rmbDown).count) downs, \(rig.times(.rmbUp).count) ups")
    precondition(rig.times(.pull).count == 1 && rig.times(.jerkUp).isEmpty && rig.detector.isRmbLatched)
    // A pull while latched is recognized and does nothing.
    rig.drive(seconds: 0.5, push: pullLobes)
    precondition(rig.times(.pull).count == 2 && rig.times(.rmbDown).count == 1 && rig.times(.rmbUp).isEmpty, "second pull changed the latch")
    // A push while latched does nothing either.
    rig.drive(seconds: 1)
    rig.drive(seconds: 1.5, push: pushLobes)
    precondition(rig.times(.rmbUp).isEmpty && rig.detector.isRmbLatched, "push released the latch")
    // A jerk up while latched releases exactly once (bow shot) with no click, masks the camera and rolls the aim back.
    let downsBefore = rig.times(.rmbDown).count
    let rollbacksBefore = has(rig, isRollback)
    rig.drive(seconds: 1)
    rig.drive(seconds: 1.5, down: jerkUpLobes)
    precondition(rig.times(.rmbUp).count == 1 && rig.times(.rmbDown).count == downsBefore, "bow shot: \(rig.times(.rmbUp).count) ups, \(rig.times(.rmbDown).count) downs")
    precondition(rig.times(.bowShot).count == 1 && rig.times(.jerkUp).isEmpty && !rig.detector.isRmbLatched && rig.times(.lmbDown).isEmpty)
    precondition(rig.count(.maskEnd) == has(rig, isMaskStart), "bow shot left the camera masked")
    precondition(has(rig, isRollback) == rollbacksBefore + 1, "bow shot did not roll the aim back")
    // After the shot a jerk up is a plain click again.
    rig.drive(seconds: 1)
    rig.drive(seconds: 0.6, down: jerkUpLobes)
    precondition(rig.times(.rmbDown).count == downsBefore + 1 && rig.times(.jerkUp).count == 1)

    // Twist: clockwise → scroll +1, counter-clockwise → -1, exactly one scroll each, nothing else pressed.
    for sign in [1.0, -1.0] {
        rig = Rig(config)
        rig.drive(seconds: calmBefore)
        rig.drive(seconds: 1.5, roll: { twistLobes($0, sign: sign) })
        precondition(has(rig, isScroll) == 1 && rig.times(.scroll(Int(sign))).count == 1, "twist \(sign): \(has(rig, isScroll)) scrolls")
        precondition(rig.times(.twist).count == 1 && rig.times(.lmbDown).isEmpty && rig.times(.rmbDown).isEmpty, "twist pressed a button")
        precondition(has(rig, isMaskStart) == 1 && rig.count(.maskEnd) == 1, "twist mask: \(has(rig, isMaskStart)) starts, \(rig.count(.maskEnd)) ends")
    }

    // Twist chaining: a second twist 0.16 s of calm after the first (less than arm_calm_ms) scrolls too, in either direction;
    // without chaining it is vetoed. A single twist still scrolls once, so its return lobe never scrolls.
    for (first, second) in [(1.0, -1.0), (1.0, 1.0)] {
        for chain in [true, false] {
            var chainConfig = config
            if !chain { chainConfig.twistChainMs = 0 }
            rig = Rig(chainConfig)
            rig.drive(seconds: calmBefore)
            rig.drive(seconds: 0.34, roll: { twistLobes($0, sign: first) })
            rig.drive(seconds: 0.16)
            rig.drive(seconds: 1.5, roll: { twistLobes($0, sign: second) })
            let scrolls = has(rig, isScroll)
            precondition(scrolls == (chain ? 2 : 1), "twists \(first), \(second), chaining \(chain): \(scrolls) scrolls")
            if chain { precondition(rig.times(.scroll(Int(first))).count >= 1 && rig.times(.scroll(Int(second))).count >= 1 && rig.times(.veto).isEmpty, "chained twists: wrong directions or a veto") }
        }
    }
    // Chaining is for twists only: a jerk down right after a twist (no calm arming) is still not accepted.
    rig = Rig(config)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 0.34, roll: { twistLobes($0, sign: 1) })
    rig.drive(seconds: 0.16)
    rig.drive(seconds: 1.0, down: { t in lobe(t, start: 0, length: 0.12, peak: 1.7) - lobe(t, start: 0.12, length: 0.12, peak: 2.0) })
    precondition(rig.times(.lmbDown).isEmpty, "a jerk right after a twist pressed without calm arming")

    // One-way roll (the case is turned and stays turned, e.g. a put-down): no scroll, the mask is given back.
    rig = Rig(config)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 2, roll: { lobe($0, start: 0, length: 0.12, peak: 600) })
    precondition(has(rig, isScroll) == 0 && rig.times(.twist).isEmpty, "one-way roll scrolled")
    precondition(has(rig, isMaskStart) == 1 && rig.count(.maskEnd) == 1, "one-way roll mask: \(has(rig, isMaskStart)) starts, \(rig.count(.maskEnd)) ends")
    // A weak or spiky roll (high rate, a few degrees) is no twist either.
    rig = Rig(config)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 1.5, roll: { lobe($0, start: 0, length: 0.02, peak: 800) - lobe($0, start: 0.02, length: 0.02, peak: 800) })
    precondition(has(rig, isScroll) == 0, "a shock scrolled")

    // A twist whose translation points along the case axis (the first twist_ccw rep: 598 dps, down share 0.90 of 0.88 g) is no jerk down.
    rig = Rig(config)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 1.5, down: { t in lobe(t, start: 0, length: 0.12, peak: 0.9) }, roll: { twistLobes($0, sign: -1) })
    precondition(rig.times(.lmbDown).isEmpty && rig.times(.rmbDown).isEmpty, "twist with case-axis translation pressed a button")

    // Jerk is not a push or twist and vice versa: a jerk (down) fires no RMB/scroll; the push and twist tests above fired no LMB.
    rig = Rig(config)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 1.5, down: { t in lobe(t, start: 0, length: 0.12, peak: 1.7) - lobe(t, start: 0.12, length: 0.12, peak: 2.0) })
    precondition(rig.times(.lmbDown).count == 1 && rig.times(.rmbDown).isEmpty && has(rig, isScroll) == 0, "jerk down fired a right-button or wheel gesture")

    // Tilted case: the arm is raised or lowered, so the world vertical is `deg` from neutral_up while the wrist flick still moves the case
    // along its own axis (neutral_up). Jerk up and jerk down must work at ±60°, with the wrist rotating during the flick; measured against
    // the world vertical their share would be cos 60° = 0.5, below the 0.8 direction ratio, which is how they used to fail (live_1200).
    let nUp = SIMD3<Double>(config.neutralUp[0], config.neutralUp[1], config.neutralUp[2]) / length(SIMD3<Double>(config.neutralUp[0], config.neutralUp[1], config.neutralUp[2]))
    let pitchDir = (fwd - dot(fwd, nUp) * nUp) / length(fwd - dot(fwd, nUp) * nUp)
    func tilted(_ deg: Double) -> SIMD3<Double> { cos(deg * Double.pi / 180) * nUp + sin(deg * Double.pi / 180) * pitchDir }
    precondition(abs(dot(tilted(60), nUp)) < config.jerkUpDirectionRatio && abs(dot(tilted(-60), nUp)) < config.jerkUpDirectionRatio, "tilted jerk tests are void: the world share is not below the direction ratio")
    for deg in [60.0, -60.0] {
        rig = Rig(config); rig.axis = nUp; rig.upVec = tilted(deg)
        rig.drive(seconds: calmBefore)
        rig.drive(seconds: 1.5, down: { t in lobe(t, start: 0, length: 0.12, peak: 1.7) - lobe(t, start: 0.12, length: 0.12, peak: 2.0) }, roll: { t in t < 0.2 ? 150 : 0 })
        rig.drive(seconds: 1)
        rig.drive(seconds: 1.5, down: jerkUpLobes, roll: { t in t < 0.2 ? 150 : 0 })
        precondition(rig.times(.lmbDown).count == 1 && rig.times(.rmbDown).count == 1 && rig.times(.veto).isEmpty && rig.times(.pull).isEmpty,
                     "tilt \(deg)°: \(rig.times(.lmbDown).count) LMB, \(rig.times(.rmbDown).count) RMB, \(rig.times(.veto).count) vetoes, \(rig.times(.pull).count) pulls, expected 1, 1, 0, 0")
    }
    // A bow drawn in the neutral pose and released with the arm raised: pull at the neutral tilt, then a jerk up at 60° is the bow shot.
    rig = Rig(config); rig.axis = nUp
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 3, push: pullLobes)
    precondition(rig.detector.isRmbLatched)
    rig.upVec = tilted(60)
    rig.drive(seconds: 1)
    rig.drive(seconds: 1.5, down: jerkUpLobes, roll: { t in t < 0.2 ? 150 : 0 })
    precondition(rig.times(.bowShot).count == 1 && !rig.detector.isRmbLatched && rig.times(.rmbDown).count == 1, "bow shot at 60°: \(rig.times(.bowShot).count) shots")
    // Pull is horizontal (world forward): with the case tilted 40° a toward-yourself motion along the world horizontal is still a pull ...
    rig = Rig(config); rig.axis = nUp; rig.upVec = tilted(40)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 2, push: pullLobes)
    precondition(rig.times(.pull).count == 1 && rig.detector.isRmbLatched, "pull at 40°: \(rig.times(.pull).count) pulls")
    // ... but a jerk up at 60° (a case-axis motion that leans toward you by sin 60° = 0.87) is not a pull.
    var lowPull = config; lowPull.pullOnsetG = 0.55      // the level in config.json: the pull then fires on the ramp, before the jerk up reaches its own onset
    rig = Rig(lowPull); rig.axis = nUp; rig.upVec = tilted(60)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 1.5, down: jerkUpLobes)
    precondition(rig.times(.pull).isEmpty && rig.times(.jerkUp).count == 1, "a jerk up at 60° was taken for a pull: \(rig.times(.pull).count) pulls, \(rig.times(.jerkUp).count) jerk ups")

    // The mask ends on rotation calm, before the refractory (pull_brake_ms) is over, and the braking lobe still starts nothing:
    // a jerk up whose wrist rotation stops after 0.1 s, followed by a downward braking lobe that would be a jerk down.
    func jerkUpWithRotation(_ cfg: Config) -> Rig {
        var r = Rig(cfg)
        r.drive(seconds: calmBefore)
        r.drive(seconds: 1.5, down: { t in -lobe(t, start: 0, length: 0.12, peak: 1.7) + lobe(t, start: 0.12, length: 0.12, peak: 2.0) }, roll: { t in lobe(t, start: 0, length: 0.1, peak: 300) })
        return r
    }
    rig = jerkUpWithRotation(config)
    let maskEndAt = rig.events.first { $0.e == .maskEnd }!.t - rig.times(.rmbDown)[0]
    precondition(rig.count(.maskEnd) == 1 && maskEndAt < config.pullBrakeMs / 1000 - 0.05, "mask end \(maskEndAt * 1000) ms after the onset, expected before the refractory (\(config.pullBrakeMs) ms) ends")
    precondition(rig.times(.lmbDown).isEmpty && rig.times(.veto).isEmpty && rig.times(.rmbDown).count == 1, "the braking lobe after an early mask end started a gesture")
    var slowMask = config; slowMask.maskRotCalmMs = 1e9
    var slow = jerkUpWithRotation(slowMask)
    precondition(slow.events.first { $0.e == .maskEnd }!.t - slow.times(.rmbDown)[0] > maskEndAt + 0.1, "without the rotation rule the mask does not end later")
    _ = slow.t; slow.t = 0

    // The release threshold is mask_release_dps, not calm_dps: the wrist keeps turning at 100 dps (above calm_dps 40, below 140) after the
    // jerk and the mask still ends early; with the release at calm_dps it lasts until the timeout. A veto keeps the calm_dps release.
    func jerkUpSlowTail(_ cfg: Config) -> Rig {
        var r = Rig(cfg)
        r.drive(seconds: calmBefore)
        r.drive(seconds: 1.5, down: jerkUpLobes, roll: { t in lobe(t, start: 0, length: 0.1, peak: 300) + (t >= 0.1 && t < 0.9 ? 100 : 0) })
        return r
    }
    rig = jerkUpSlowTail(config)
    let tailEnd = rig.events.first { $0.e == .maskEnd }!.t - rig.times(.rmbDown)[0]
    var strictRelease = config; strictRelease.maskReleaseDps = config.calmDps
    var strict = jerkUpSlowTail(strictRelease)
    let strictEnd = strict.events.first { $0.e == .maskEnd }!.t - strict.times(.rmbDown)[0]
    precondition(tailEnd < 0.25 && strictEnd > 0.6, "release at mask_release_dps: mask end \(tailEnd * 1000) ms, at calm_dps \(strictEnd * 1000) ms after the onset")
    _ = strict.t; strict.t = 0
    rig = Rig(config)
    rig.drive(seconds: 1, side: { _ in 0.5 })
    rig.drive(seconds: 1.5, down: { t in lobe(t, start: 0, length: 0.12, peak: 1.7) - lobe(t, start: 0.12, length: 0.12, peak: 2.0) }, side: { _ in 0.5 },
              roll: { t in lobe(t, start: 0, length: 0.1, peak: 300) + (t >= 0.1 && t < 0.9 ? 100 : 0) })
    let vetoAt = rig.times(.veto)[0]
    let vetoEnd = rig.events.first { $0.e == .maskEnd && $0.t > vetoAt }!.t - vetoAt
    precondition(rig.times(.veto).count == 1 && vetoEnd > 0.5, "a veto's mask ended \(vetoEnd * 1000) ms after the onset at 100 dps, expected the calm_dps release")

    // A shake after an early-released jerk down: the camera is given back right after the click, the wrist keeps turning (100 dps yaw,
    // below mask_release_dps) and that leaks into the aim; when the second stroke makes it a shake the mask comes back and the leak
    // since the release is rolled back, so the net aim change over the whole gesture is about zero. One click and one hold, no tear.
    do {
        let cam = Camera(config: config)
        let det = GestureDetector(config: config)
        let g = SIMD3<Double>(0.02, -0.94, -0.35), gUp = g / length(g)
        let bias = SIMD3<Double>(0.24, 0.96, 0.26)
        var t = 0.0, nextTick = 0.0, net = SIMD2<Double>(0, 0), peak = 0.0
        var pending = SIMD2<Double>(0, 0), presses = 0, shakes = 0, rollbacks = 0, rolledBackAfterRelease = false, released = false
        while t < 3.0 + 5.0 {
            let local = t - 3.0
            let swing = local >= 0 && local < 2 ? 3.0 * sin(2 * Double.pi * 3 * local) * (sin(2 * Double.pi * 3 * local) > 0 ? 0.7 : 1) : 0
            let turn = local >= 0.05 && local < 0.7 ? 100.0 : 0
            let a = g - swing * gUp, w = bias + turn * gUp
            let recv = t + 0.002
            cam.feed(MotionSample(kind: .accel, sensorTime: t, receivedUptime: recv, x: -a.x, y: -a.y, z: -a.z))
            if let frame = cam.feed(MotionSample(kind: .gyro, sensorTime: t, receivedUptime: recv, x: w.x, y: w.y, z: w.z)) {
                for e in det.feed(frame, now: recv) {
                    switch e {
                    case .maskStart(let from): cam.mask(from: from)
                    case .maskEnd: cam.unmask(); if local < 0.3 { released = true }
                    case .rollback(let from): let r = cam.rollback(from: from); pending += SIMD2(Double(r.dx), Double(r.dy)); rollbacks += 1; if released { rolledBackAfterRelease = true }
                    case .action(.lmbDown): presses += 1
                    case .recognized(.shake): shakes += 1
                    default: break
                    }
                }
            }
            while nextTick <= recv {
                let c = cam.tick(now: nextTick)
                net += SIMD2(Double(c.dx), Double(c.dy)) + pending; pending = SIMD2(0, 0)
                peak = max(peak, abs(net.x) + abs(net.y))
                nextTick += 1 / 240
            }
            t += 0.005
        }
        precondition(released && rolledBackAfterRelease && shakes == 1, "shake test is void: released \(released), rolled back after the release \(rolledBackAfterRelease), \(shakes) shakes")
        precondition(presses == 2 && !cam.isMasked, "shake after an early release: \(presses) presses (click + hold), masked \(cam.isMasked)")
        precondition(peak > 100, "the wrist rotation never leaked before the shake (peak \(peak) counts), test is void")
        precondition(abs(net.x) <= 3 && abs(net.y) <= 3, "net aim change after the shake's rollback \(net) counts (peak \(peak)), expected about 0")
    }

    // Pause: flat and calm for pause_still_ms. The latched RMB is released by the caller on .pause; the detector forgets it.
    rig = Rig(config)
    rig.drive(seconds: calmBefore)
    rig.drive(seconds: 3, push: pullLobes)
    precondition(rig.detector.isRmbLatched)
    rig.upVec = SIMD3(1, 0, 0)
    let flatStart = rig.t
    rig.drive(seconds: 2)
    let pauses = rig.times(.pause)
    precondition(pauses.count == 1 && rig.detector.isPaused && !rig.detector.isRmbLatched, "pause: \(pauses.count)")
    precondition(abs(pauses[0] - flatStart - config.pauseStillMs / 1000) < 0.03, "paused after \(pauses[0] - flatStart) s")
    precondition(has(rig, isMaskStart) >= 2, "pause did not mask the camera")
    // While paused nothing is recognized, even a violent jerk and push.
    let downsPaused = rig.times(.lmbDown).count + rig.times(.rmbDown).count
    rig.drive(seconds: 1, down: { t in lobe(t, start: 0, length: 0.12, peak: 1.7) }, push: { t in lobe(t, start: 0.5, length: 0.12, peak: 1.4) })
    precondition(rig.times(.lmbDown).count + rig.times(.rmbDown).count == downsPaused && rig.times(.resume).isEmpty, "something fired while paused")
    // Pick-up: back near neutral for resume_ms → resume once. The next gesture needs fresh calm arming first.
    rig.upVec = up
    let pickUp = rig.t
    rig.drive(seconds: 0.2, down: { t in lobe(t, start: 0, length: 0.12, peak: 1.7) })     // still shaking in the hand
    precondition(rig.times(.resume).isEmpty, "resumed before resume_ms")
    rig.drive(seconds: 0.3, down: { t in lobe(t, start: 0, length: 0.12, peak: 1.7) })     // a jerk-like bump right after resume
    precondition(rig.times(.resume).count == 1 && abs(rig.times(.resume)[0] - pickUp - config.resumeMs / 1000) < 0.03, "resume: \(rig.times(.resume))")
    precondition(!rig.detector.isPaused && rig.times(.lmbDown).count + rig.times(.rmbDown).count == downsPaused, "a gesture fired right after resume")
    rig.drive(seconds: 0.6)
    rig.drive(seconds: 0.5, down: { t in lobe(t, start: 0, length: 0.12, peak: 1.7) })
    precondition(rig.times(.lmbDown).count == 1, "no gesture after the fresh calm arming")
    // reset() (panic key, stream loss) forgets a latch and a pause.
    var latched = Rig(config)
    latched.drive(seconds: calmBefore)
    latched.drive(seconds: 2, push: pullLobes)
    latched.detector.reset()
    precondition(!latched.detector.isRmbLatched)
    rig.upVec = SIMD3(1, 0, 0)
    rig.drive(seconds: 1.5)
    precondition(rig.detector.isPaused)
    rig.detector.reset()
    precondition(!rig.detector.isPaused)

    print("PASS: gestures (veto of unarmed jerk and twist shapes, early-settle release, rollback of the wind-up, press at onset, click release, braking and sideways ignored, refractory, shake hold and release, calm arming, mask end on rotation calm (jerk down releases at once, mask_release_dps, veto keeps calm_dps, shake after an early release rolls back to net 0), jerks and bow shot at ±60° tilt along the case axis, jerk up is no pull, twist with case-axis translation is no jerk, twist chaining; right button, wheel and pause: jerk up click, wind-ups both ways, push ignored, rebound, pull latch, bow shot, twist both ways, one-way roll, pause and resume)")
}
