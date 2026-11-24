import Foundation

// Offline replay of the recordings through Camera: `MinePointer --replay [take ...]`.
// Samples are fed in arrival order and tick(now:) is called at 240 Hz on the same clock, as live.

private let tickRate = 240.0
private let warmUpSeconds = 5.0
private let warmUpFromSessionStart = true
private let tailSeconds = 0.3             // ticks after the take end, so the jitter buffer drains
private let movingDps = 10.0              // |ω| above this counts as "moving" for the step metrics
private let pauseLookBackSeconds = 30.0   // pause/resume shortly before a take starts are listed too (the case is put down before recording starts)
private let pauseLabels = ["pause", "resume"]
private let settleSeconds = 5.0        // a hold-still take starts with the hand settling; also reported without it
private let peakWindowTicks = 12          // 50 ms window for the peak camera speed
private let detailed = ProcessInfo.processInfo.environment["MINEPOINTER_REPLAY_DETAIL"] == "1"   // per-gesture aim change listing

private struct Take {
    let name: String
    let start: Double
    let end: Double
}

private struct Press {
    let down: Double            // uptime
    var up: Double?
    var hold: Double? { up.map { $0 - down } }
}

private struct TakeResult {
    let name: String
    let start: Double
    let presses: [Press]                        // LMB presses that began inside the take
    let residuals: [Double]                     // net camera degrees emitted during each gesture mask window
    let residualsByGesture: [String: [Double]]  // the same, per recognized gesture name (pause windows excluded)
    let netByGesture: [String: [Double]]        // |net aim change| over 2.5 s from the calm exit, degrees, per recognized gesture name (veto included, pause excluded)
    let marks: [(at: Double, label: String)]    // recognized gestures and button/scroll/pause actions inside the take, offset in the take
    let maskMs: [Double]                        // length of each gesture's camera mask (mask start to end), ms, per recognized gesture (pause excluded)
    let falseMasks: [(at: Double, ms: Double)]  // camera masks that ended without any press (dropped candidates), offset in the take
    let shakeSnaps: [Double]                    // degrees of aim taken back when a shake re-masked a camera that a jerk down had already released (the snap the player sees)
    let shakes: Int                             // recognized shakes (snaps are a subset)
    let strongTimes: [Double]                   // arrival times of frames with |vertical acceleration| ≥ shakeStrokeG
    let seconds: Double
    let yawDeg: Double, pitchDeg: Double        // sums of |dx|, |dy| in degrees
    let netYawDeg: Double, netPitchDeg: Double
    let totalCounts: Int
    let movingTicks: Int
    let movingNonzero: Int
    let longestEmptyRun: Int
    let runHistogram: [Int: Int]                // empty-run length → how many
    let maxTickCounts: Int
    let settledPerMinute: Double                // path °/min after the first `settleSeconds` of the take
    let settledCounts: Int
    let settledNetPerMinute: Double
    let peakDegPerSecond: Double

    var perMinute: Double { (yawDeg + pitchDeg) / seconds * 60 }
    var netPerMinute: Double { (netYawDeg.magnitude + netPitchDeg.magnitude) / seconds * 60 }
}

private func loadTakes() -> [Take] {
    let url = logsFolder.appendingPathComponent("takes.csv")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var byName: [String: Take] = [:], order: [String] = []
    for line in text.split(whereSeparator: \.isNewline).dropFirst() {
        let p = line.split(separator: ",")
        guard p.count == 3, let a = Double(p[1]), let b = Double(p[2]) else { continue }
        let name = String(p[0])
        if let earlier = byName[name] {                        // re-recorded take: the last row keeps the name, the earlier one is "<name>_old"
            byName[name + "_old"] = Take(name: name + "_old", start: earlier.start, end: earlier.end)
            if !order.contains(name + "_old") { order.append(name + "_old") }
        } else { order.append(name) }
        byName[name] = Take(name: name, start: a, end: b)
    }
    return order.compactMap { byName[$0] }
}

private func loadSamples() -> [MotionSample] {
    let files = (try? FileManager.default.contentsOfDirectory(at: logsFolder, includingPropertiesForKeys: nil)) ?? []
    var samples: [MotionSample] = []
    for file in files.filter({ $0.lastPathComponent.hasPrefix("helper-") && $0.pathExtension == "txt" }) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for line in text.split(whereSeparator: \.isNewline) {
            if let s = MotionSample(helperLine: line) { samples.append(s) }
        }
    }
    // Arrival order; the sort is not stable in Swift 5 so break ties by sensor time.
    samples.sort { ($0.receivedUptime, $0.sensorTime) < ($1.receivedUptime, $1.sensorTime) }
    return samples
}

/// One helper log: the span of its samples and the axes of its `calib` meta lines (the grip changes between sessions).
private struct SessionAxes {
    let name: String            // helper-YYYYmmdd-HHMMSS
    let first: Double, last: Double
    let calibs: [(at: Double, up: [Double], forward: [Double])]
}

/// Recordings made before the calibration wizard have no calib line: takes starting before this uptime were made in the
/// old grip (logs/config.before-calib-20261124.json), later ones in the grip of the run config.
private let calibrationUptime = 177950.0
private let oldGripConfig = logsFolder.appendingPathComponent("config.before-calib-20261124.json")

private func loadSessionAxes() -> [SessionAxes] {
    let files = (try? FileManager.default.contentsOfDirectory(at: logsFolder, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.lastPathComponent.hasPrefix("helper-") && $0.pathExtension == "txt" }.compactMap { file in
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let times = text.split(whereSeparator: \.isNewline).lazy.compactMap { MotionSample(helperLine: $0)?.receivedUptime }
        guard let first = times.first, let last = text.split(whereSeparator: \.isNewline).reversed().lazy.compactMap({ MotionSample(helperLine: $0)?.receivedUptime }).first else { return nil }
        let meta = (try? String(contentsOf: file.deletingPathExtension().appendingPathExtension("meta"), encoding: .utf8)) ?? ""
        let calibs = meta.split(whereSeparator: \.isNewline).compactMap { line -> (at: Double, up: [Double], forward: [Double])? in
            let p = line.split(separator: " ")       // calib <uptime> up x y z forward x y z
            guard p.count == 10, p[0] == "calib", p[2] == "up", p[6] == "forward", let at = Double(p[1]) else { return nil }
            let v = p.compactMap { Double($0) }
            guard v.count == 7 else { return nil }
            return (at, Array(v[1...3]), Array(v[4...6]))
        }
        return SessionAxes(name: file.deletingPathExtension().lastPathComponent, first: first, last: last, calibs: calibs)
    }.sorted { $0.first < $1.first }
}

/// The config a take is replayed with: the run config, with the axes of the grip the take was recorded in.
private func axesConfig(for take: Take, sessions: [SessionAxes], runConfig: Config) -> (config: Config, source: String) {
    var config = runConfig
    let session = sessions.last { $0.first <= take.start && take.start <= $0.last } ?? sessions.last { $0.first <= take.start }
    if let session, let calib = session.calibs.last(where: { $0.at <= take.start }) {
        config.neutralUp = calib.up
        config.forwardAxis = calib.forward
        return (config, "calib " + session.name.dropFirst("helper-".count + 9))
    }
    if take.start < calibrationUptime, FileManager.default.fileExists(atPath: oldGripConfig.path) {
        let old = Config.load(from: oldGripConfig)
        config.neutralUp = old.neutralUp
        config.forwardAxis = old.forwardAxis
        return (config, "before-calib")
    }
    return (config, "config")
}

private func replay(_ take: Take, samples: [MotionSample], config: Config) -> TakeResult? {
    let stop = take.end + tailSeconds
    // First sample at or after the nominal warm-up start.
    var lo = 0, hi = samples.count
    while lo < hi { let mid = (lo + hi) / 2; if samples[mid].receivedUptime < take.start - warmUpSeconds { lo = mid + 1 } else { hi = mid } }
    var index = lo
    guard index < samples.count, samples[index].receivedUptime < take.end else { return nil }
    // Extend the warm-up back to the start of the helper session: most takes are preceded by motion, not by a still
    // period, so 5 s is not enough to learn the bias. Live, the camera also runs from the session start.
    if warmUpFromSessionStart {
        while index > 0 {
            let a = samples[index - 1], b = samples[index]
            if b.receivedUptime - a.receivedUptime > 5 || abs((b.sensorTime - a.sensorTime) - (b.receivedUptime - a.receivedUptime)) > 2 { break }
            index -= 1
        }
    }
    let warmStart = samples[index].receivedUptime

    // Gyro in this window by sensor time, for the "moving" flag. Arrival offset = its minimum over the window.
    var window: [(sensor: Double, mag: Double)] = []
    var minOffset = Double.infinity
    var j = index
    while j < samples.count, samples[j].receivedUptime <= stop {
        if samples[j].kind == .gyro {
            let v = samples[j].vector
            window.append((samples[j].sensorTime, (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()))
            minOffset = min(minOffset, samples[j].receivedUptime - samples[j].sensorTime)
        }
        j += 1
    }
    window.sort { $0.sensor < $1.sensor }
    func omega(atSensorTime t: Double) -> Double {
        var a = 0, b = window.count
        while a < b { let m = (a + b) / 2; if window[m].sensor < t { a = m + 1 } else { b = m } }
        guard !window.isEmpty else { return 0 }
        if a == window.count { return window[a - 1].mag }
        if a > 0, abs(window[a - 1].sensor - t) < abs(window[a].sensor - t) { return window[a - 1].mag }
        return window[a].mag
    }

    let camera = Camera(config: config)
    let detector = GestureDetector(config: config)
    let debugGestures = ProcessInfo.processInfo.environment["MINEPOINTER_GESTURE_DEBUG"] == "1"
    if debugGestures {
        detector.trace = { t, why in
            let at = t + minOffset - take.start
            if at >= 0, at <= take.end - take.start { print(String(format: "    why %7.2f s: ", at) + why) }
        }
    }
    var allPresses: [Press] = []
    var windows: [(from: Double, end: Double?, presses: Int, calmExit: Double?, name: String?)] = []       // sensor time; presses = count at the mask start
    var allMarks: [(at: Double, label: String)] = []     // uptime, label
    var strong: [Double] = []
    var tickTimes: [Double] = []
    var lastFrameTime = 0.0
    var pendingBack = (0, 0)           // rollback counts, added to the counts of the current tick
    var shakeSnaps: [Double] = [], shakes = 0
    func apply(_ events: [GestureEvent], now: Double) {
        var batchBack = 0.0                // degrees rolled back by this batch of events
        for event in events {
            if debugGestures, now >= take.start, now <= take.end { print(String(format: "    ev  %7.2f s: ", now - take.start) + "\(event)") }
            switch event {
            case .action(.lmbDown): allPresses.append(Press(down: now, up: nil))
            case .action(.lmbUp): if let i = allPresses.indices.last, allPresses[i].up == nil { allPresses[i].up = now }
            case .maskStart(let from):
                camera.mask(from: from)
                if let i = windows.indices.last, windows[i].end == nil { windows[i].from = min(windows[i].from, from) }
                else { windows.append((from, nil, allPresses.count, nil, nil)) }
            case .rollback(let from):
                if let i = windows.indices.last { windows[i].calmExit = from }
                let back = camera.rollback(from: from)
                pendingBack.0 += back.dx; pendingBack.1 += back.dy
                batchBack += Double(back.dx * back.dx + back.dy * back.dy).squareRoot() / config.countsPerDegree
                if detailed, abs(back.dx) + abs(back.dy) > 150 { print(String(format: "    detail rollback of %d, %d counts at uptime %.2f", back.dx, back.dy, now)) }
            case .maskEnd:
                camera.unmask()
                if let i = windows.indices.last, windows[i].end == nil { windows[i].end = lastFrameTime }
            case .recognized(let name):
                if name == .shake, now >= take.start, now <= take.end { shakes += 1; if batchBack > 0 { shakeSnaps.append(batchBack) } }
                allMarks.append((now, name.rawValue))
                if let i = windows.indices.last, windows[i].end == nil, windows[i].name == nil { windows[i].name = name.rawValue }
            case .action(.rmbDown): allMarks.append((now, "rmb_down"))
            case .action(.rmbUp): allMarks.append((now, "rmb_up"))
            case .action(.scroll(let dir)): allMarks.append((now, dir > 0 ? "scroll+1" : "scroll-1"))
            case .action(.pause):
                allMarks.append((now, "pause"))
                if let i = windows.indices.last, windows[i].end == nil { windows[i].name = "pause" }
            case .action(.resume):
                allMarks.append((now, "resume"))
                camera.unmask(keepBand: false)               // the pick-up is not aim
                if let i = windows.indices.last, windows[i].end == nil { windows[i].end = lastFrameTime }
            }
        }
    }
    var dxs: [Int] = [], dys: [Int] = [], moving: [Bool] = []
    var k = 0
    while true {
        let now = warmStart + Double(k) / tickRate
        if now > stop { break }
        k += 1
        while index < samples.count, samples[index].receivedUptime <= now {
            if let frame = camera.feed(samples[index]) {
                lastFrameTime = frame.time
                if abs(frame.down) >= config.shakeStrokeG { strong.append(now) }
                apply(detector.feed(frame, now: now), now: now)
            }
            index += 1
        }
        apply(detector.tick(now: now), now: now)
        var c = camera.tick(now: now)
        c.dx += pendingBack.0; c.dy += pendingBack.1; pendingBack = (0, 0)
        guard now >= take.start, now <= take.end else { continue }
        dxs.append(c.dx); dys.append(c.dy); tickTimes.append(now)
        moving.append(omega(atSensorTime: now - config.jitterMs / 1000 - minOffset) > movingDps)
    }

    let cpd = config.countsPerDegree
    var movingTicks = 0, movingNonzero = 0, longest = 0, histogram: [Int: Int] = [:]
    var run = 0, runAllMoving = true, seenNonzero = false, maxTick = 0
    for i in 0..<dxs.count {
        let nonzero = dxs[i] != 0 || dys[i] != 0
        maxTick = max(maxTick, Int((Double(dxs[i] * dxs[i] + dys[i] * dys[i])).squareRoot().rounded()))
        if moving[i] { movingTicks += 1; if nonzero { movingNonzero += 1 } }
        if nonzero {
            if run > 0, seenNonzero, runAllMoving { longest = max(longest, run); histogram[run, default: 0] += 1 }
            run = 0; runAllMoving = true; seenNonzero = true
        } else {
            run += 1
            if !moving[i] { runAllMoving = false }
        }
    }
    let settledFrom = Int(settleSeconds * tickRate)
    let settledCounts = zip(dxs, dys).dropFirst(settledFrom).reduce(0) { $0 + abs($1.0) + abs($1.1) }
    let settledNet = (Double(dxs.dropFirst(settledFrom).reduce(0, +)), Double(dys.dropFirst(settledFrom).reduce(0, +)))
    let settledSeconds = max(0.001, take.end - take.start - settleSeconds)
    var peak = 0.0
    if dxs.count >= peakWindowTicks {
        var sx = 0, sy = 0
        for i in 0..<dxs.count {
            sx += dxs[i]; sy += dys[i]
            if i >= peakWindowTicks { sx -= dxs[i - peakWindowTicks]; sy -= dys[i - peakWindowTicks] }
            if i >= peakWindowTicks - 1 {
                let speed = Double(sx * sx + sy * sy).squareRoot() / cpd / (Double(peakWindowTicks) / tickRate)
                peak = max(peak, speed)
            }
        }
    }
    // Camera residual per gesture: the output emitted for sensor times from the mask start to the mask end.
    let jitter = config.jitterMs / 1000
    var residuals: [Double] = []
    var byGesture: [String: [Double]] = [:]
    var netBy: [String: [Double]] = [:]
    var falseMasks: [(at: Double, ms: Double)] = []
    var maskMs: [Double] = []
    for w in windows {
        let start = w.calmExit ?? w.from           // a gesture's aim change counts from the calm exit; a dropped candidate from its mask start
        guard let end = w.end, start + minOffset >= take.start, end + minOffset <= take.end else { continue }
        if w.name == nil, allPresses.count == w.presses || allPresses.first(where: { $0.down >= w.from + minOffset }) == nil {
            falseMasks.append((start + minOffset - take.start, (end - start) * 1000))
        }
        var sx = 0, sy = 0
        for i in 0..<tickTimes.count where tickTimes[i] >= start + minOffset + jitter && tickTimes[i] <= end + minOffset + jitter + 0.02 {
            sx += dxs[i]; sy += dys[i]
        }
        let residual = Double(sx * sx + sy * sy).squareRoot() / cpd
        residuals.append(residual)
        if detailed, residual > 1 { print(String(format: "    detail WINDOW name %@ at %.2f s residual %.2f° from %.2f end %.2f calmExit %@", (w.name ?? "-") as NSString, start + minOffset - take.start, residual, w.from + minOffset - take.start, end + minOffset - take.start, String(describing: w.calmExit.map { $0 + minOffset - take.start }))) }
        if detailed, let name = w.name {
            // Net aim change from the calm exit to 2.5 s later: what the player sees as "the gesture moved the camera".
            var ax = 0, ay = 0
            for i in 0..<tickTimes.count where tickTimes[i] >= start + minOffset + jitter && tickTimes[i] <= start + minOffset + jitter + 2.5 {
                ax += dxs[i]; ay += dys[i]
            }
            print(String(format: "    detail %@ at %.2f s: in mask %.2f° (%.0f ms), net over 2.5 s yaw %+.1f° pitch %+.1f° (pitch + = down)",
                         name as NSString, start + minOffset - take.start, residual, (end - w.from) * 1000, Double(ax) / cpd, Double(ay) / cpd))
        }
        if let name = w.name, name != "pause" {
            var ax = 0, ay = 0
            for i in 0..<tickTimes.count where tickTimes[i] >= start + minOffset + jitter && tickTimes[i] <= start + minOffset + jitter + 2.5 {
                ax += dxs[i]; ay += dys[i]
            }
            netBy[name, default: []].append(Double(ax * ax + ay * ay).squareRoot() / cpd)
        }
        if let name = w.name, name != "pause" { byGesture[name, default: []].append(residual); maskMs.append((end - w.from) * 1000) }
    }
    return TakeResult(
        name: take.name, start: take.start,
        presses: allPresses.filter { $0.down >= take.start && $0.down <= take.end },
        residuals: residuals, residualsByGesture: byGesture, netByGesture: netBy,
        marks: allMarks.filter { $0.at >= take.start - (pauseLabels.contains($0.label) ? pauseLookBackSeconds : 0) && $0.at <= take.end }.map { ($0.at - take.start, $0.label) },
        maskMs: maskMs, falseMasks: falseMasks, shakeSnaps: shakeSnaps, shakes: shakes, strongTimes: strong.filter { $0 >= take.start && $0 <= take.end },
        seconds: take.end - take.start,
        yawDeg: Double(dxs.reduce(0) { $0 + abs($1) }) / cpd, pitchDeg: Double(dys.reduce(0) { $0 + abs($1) }) / cpd,
        netYawDeg: Double(dxs.reduce(0, +)) / cpd, netPitchDeg: Double(dys.reduce(0, +)) / cpd,
        totalCounts: dxs.reduce(0) { $0 + abs($1) } + dys.reduce(0) { $0 + abs($1) },
        movingTicks: movingTicks, movingNonzero: movingNonzero, longestEmptyRun: longest, runHistogram: histogram,
        maxTickCounts: maxTick, settledPerMinute: Double(settledCounts) / cpd / settledSeconds * 60, settledCounts: settledCounts,
        settledNetPerMinute: (settledNet.0 * settledNet.0 + settledNet.1 * settledNet.1).squareRoot() / cpd / settledSeconds * 60,
        peakDegPerSecond: peak)
}

private func f1(_ v: Double) -> String { String(format: "%.1f", v) }

func runReplay(arguments: [String]) {
    let config = ProcessInfo.processInfo.environment["MINEPOINTER_CONFIG"].map { Config.load(from: URL(fileURLWithPath: $0)) } ?? Config.load()   // sweeps without touching the live config
    let wanted = arguments.filter { !$0.hasPrefix("--") }
    let takes = loadTakes()
    let selected = wanted.isEmpty ? takes : takes.filter { wanted.contains($0.name) }
    for name in wanted where !takes.contains(where: { $0.name == name }) { print("unknown take: \(name)") }
    let samples = loadSamples()
    print("replay: \(samples.count) samples, \(selected.count) takes, gain \(config.gain), jitter \(config.jitterMs) ms, "
          + "\(f1(config.countsPerDegree)) counts/deg")

    let sessions = loadSessionAxes()
    let sources = selected.map { ($0, axesConfig(for: $0, sessions: sessions, runConfig: config)) }
    let grouped = Dictionary(grouping: sources, by: { $0.1.source })
    print("axes: " + grouped.keys.sorted().map { "\($0): " + grouped[$0]!.map { $0.0.name }.joined(separator: " ") }.joined(separator: "; "))

    var results: [String: TakeResult] = [:]
    for (take, axes) in sources {
        guard let r = replay(take, samples: samples, config: axes.config) else { print("\(take.name): no samples"); continue }
        results[take.name] = r
        let moveFraction = r.movingTicks > 0 ? String(format: "%.0f%%", 100 * Double(r.movingNonzero) / Double(r.movingTicks)) : "n/a"
        print(String(format: "%-17@ %5.1fs  yaw %7.1f° pitch %7.1f° (net %7.1f° %7.1f°)  %6.1f°/min (net %6.1f°/min)  nonzero while moving %@ of %d ticks  longest empty run %d  max tick %d counts  peak %.0f°/s",
                     take.name as NSString, r.seconds, r.yawDeg, r.pitchDeg, r.netYawDeg, r.netPitchDeg, r.perMinute, r.netPerMinute,
                     moveFraction as NSString, r.movingTicks, r.longestEmptyRun, r.maxTickCounts, r.peakDegPerSecond))
    }

    print("\nacceptance:")
    if let r = results["neutral_still"] {
        print("\(r.perMinute < 5 ? "PASS" : "FAIL"): neutral_still \(f1(r.perMinute))°/min total (yaw+pitch path), net \(f1(r.netPerMinute))°/min; limit 5. After the first \(Int(settleSeconds)) s (hand settling): \(f1(r.settledPerMinute))°/min path, \(f1(r.settledNetPerMinute))°/min net")
    }
    if let r = results["table_still"] {
        print("\(r.totalCounts == 0 ? "PASS" : "FAIL"): table_still \(r.totalCounts) counts; limit 0. After the first \(Int(settleSeconds)) s: \(r.settledCounts) counts")
    }
    if let r = results["aim_slow"] {
        print("\(r.longestEmptyRun <= 1 ? "PASS" : "FAIL"): aim_slow longest empty run \(r.longestEmptyRun) ticks while |ω| > \(Int(movingDps)) dps; limit 1")
    }
    for name in ["aim_slow", "aim_fast"] {
        guard let r = results[name] else { continue }
        let hist = r.runHistogram.keys.sorted().map { "\($0):\(r.runHistogram[$0]!)" }.joined(separator: " ")
        print("\(name): yaw \(f1(r.yawDeg))° pitch \(f1(r.pitchDeg))° total, peak camera speed \(f1(r.peakDegPerSecond))°/s over \(peakWindowTicks) ticks; empty runs while moving (length:count) \(hist.isEmpty ? "none" : hist)")
    }
    gestureReport(results, order: selected.map { $0.name }, config: config)
}

// MARK: Gesture report

private let repGapSeconds = 1.0       // presses closer than this (release → press) belong to one repetition
private let tearSeconds = 0.4         // a release followed by a press within this long is a tear

private func median(_ v: [Double]) -> Double {
    guard !v.isEmpty else { return 0 }
    let s = v.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

private func percentile90(_ v: [Double]) -> Double {
    guard !v.isEmpty else { return 0 }
    let s = v.sorted()
    return s[min(s.count - 1, Int((0.9 * Double(s.count)).rounded(.up)) - 1)]
}

/// Groups presses into repetitions: a press starts a new one if it comes more than repGapSeconds after the last release.
private func repetitions(_ presses: [Press]) -> [[Press]] {
    var reps: [[Press]] = []
    for p in presses {
        if let last = reps.last?.last, p.down - (last.up ?? last.down) <= repGapSeconds { reps[reps.count - 1].append(p) }
        else { reps.append([p]) }
    }
    return reps
}

private func tearCount(_ presses: [Press]) -> Int {
    var tears = 0
    for (a, b) in zip(presses, presses.dropFirst()) where a.up != nil && b.down - a.up! < tearSeconds { tears += 1 }
    return tears
}

private func gestureReport(_ results: [String: TakeResult], order: [String], config: Config) {
    print("\ngestures (LMB presses; hold in ms; residual = net camera degrees emitted while a gesture masks the camera):")
    for name in order {
        guard let r = results[name] else { continue }
        let holds = r.presses.compactMap { $0.hold }.map { $0 * 1000 }
        let hold = holds.isEmpty ? "n/a" : String(format: "min %.0f / median %.0f / max %.0f", holds.min()!, median(holds), holds.max()!)
        let res = r.residuals.isEmpty ? "n/a" : String(format: "median %.2f° / max %.2f° over %d", median(r.residuals), r.residuals.max()!, r.residuals.count)
        print("  \(name.padding(toLength: 17, withPad: " ", startingAt: 0)) presses \(r.presses.count)  hold \(hold)  residual \(res)")
        if name == "jerk_shake" {
            let reps = repetitions(r.presses)
            let perRep = Dictionary(grouping: reps, by: { $0.count }).mapValues { $0.count }
            let hist = perRep.keys.sorted().map { "\($0) press: \(perRep[$0]!) reps" }.joined(separator: ", ")
            print("    repetitions \(reps.count) (\(hist)); tears (release → press < \(Int(tearSeconds * 1000)) ms) \(tearCount(r.presses))")
            let diffs = reps.compactMap { rep -> Double? in
                guard let first = rep.first, let end = rep.last?.up else { return nil }
                let lastStrong = r.strongTimes.filter { $0 >= first.down && $0 <= end + 1 }.last ?? first.down
                return (end - first.down) - (lastStrong - first.down)
            }
            print(String(format: "    hold minus shake span (last stroke ≥ %.1f g), s: median %.2f, min %.2f, max %.2f", config.shakeStrokeG,
                         median(diffs), diffs.min() ?? 0, diffs.max() ?? 0))
        }
        let counts = Dictionary(grouping: r.marks, by: { $0.label }).mapValues { $0.count }
        if !counts.isEmpty {
            print("    events: " + counts.keys.sorted().map { "\($0) \(counts[$0]!)" }.joined(separator: ", "))
        }
        for (gesture, res) in r.residualsByGesture.sorted(by: { $0.key < $1.key }) where !["jerk_down", "shake"].contains(gesture) {
            print(String(format: "    residual of %@: median %.2f° / max %.2f° over %d", gesture as NSString, median(res), res.max()!, res.count))
        }
        // |net aim change| over 2.5 s after each gesture (what the player sees): median / p90 / max per gesture type.
        let allNet = r.netByGesture.values.flatMap { $0 }
        for (gesture, v) in r.netByGesture.sorted(by: { $0.key < $1.key }) + (r.netByGesture.count > 1 ? [("all", allNet)] : []) {
            print(String(format: "    net 2.5 s %@: median %.1f° / p90 %.1f° / max %.1f° over %d", gesture as NSString, median(v), percentile90(v), v.max()!, v.count))
        }
        if !r.maskMs.isEmpty {
            print(String(format: "    camera mask per gesture: median %.0f ms / max %.0f ms over %d", median(r.maskMs), r.maskMs.max()!, r.maskMs.count))
        }
        if r.shakes > 0 {
            print(String(format: "    shake after an early-released jerk down: %d of %d shakes rolled back; snap median %.2f° / max %.2f°", r.shakeSnaps.count, r.shakes, median(r.shakeSnaps), r.shakeSnaps.max() ?? 0))
        }
        if !r.falseMasks.isEmpty {
            let ms = r.falseMasks.map { $0.ms }
            print(String(format: "    camera masked without a press (dropped candidates): %d, masked %.0f / %.0f / %.0f ms (min / median / max)",
                         r.falseMasks.count, ms.min()!, median(ms), ms.max()!))
        }
        let listed = ["neutral_still", "aim_slow", "aim_fast", "table_still", "regrip", "put_down_pick_up", "free_play", "push_screen_old", "pull_self_old"]
        if listed.contains(name) {
            if !r.presses.isEmpty { print("    \(repetitions(r.presses).count) gesture(s); a press within \(Int(repGapSeconds * 1000)) ms of the last release belongs to the same gesture") }
            for p in r.presses {
                print(String(format: "    press at %.2f s into the take, held %@ ms", p.down - r.start, p.hold.map { String(format: "%.0f", $0 * 1000) } ?? "?"))
            }
            for m in r.marks where !["rmb_up", "resume", "shake", "shake_end"].contains(m.label) && m.label != "jerk_down" {
                print(String(format: "    %@ at %.2f s into the take", m.label as NSString, m.at))
            }
        }
    }

    func check(_ ok: Bool, _ text: String) { print("\(ok ? "PASS" : "FAIL"): \(text)") }
    print("\ngesture acceptance:")
    if let r = results["jerk_down"] {
        let holds = r.presses.compactMap { $0.hold }
        check(r.presses.count >= 23, "jerk_down \(r.presses.count) presses; need ≥ 23 of 25")
        let longest = (holds.max() ?? 0) * 1000
        check(longest <= config.clickHoldMs + 60, String(format: "jerk_down every hold short: max %.0f ms (click_hold_ms %.0f)", longest, config.clickHoldMs))
    }
    if let r = results["jerk_shake"] {
        let reps = repetitions(r.presses)
        // A shake is the jerk's short click, then one hold from the first stroke: ≤ 2 presses, and only the first gap
        // (click release → shake press) is allowed; any later tear would reset block-breaking progress mid-shake.
        let good = reps.filter { $0.count <= 2 }.count
        let midTears = reps.map { tearCount(Array($0.dropFirst())) }.reduce(0, +)
        check(good >= 18, "jerk_shake \(good) of \(reps.count) repetitions with click + one hold (≤ 2 presses); need ≥ 18")
        check(midTears == 0, "jerk_shake tears after the first stroke \(midTears); need 0")
        let diffs = reps.compactMap { rep -> Double? in
            guard let first = rep.first, let end = rep.last?.up else { return nil }
            let lastStrong = r.strongTimes.filter { $0 >= first.down && $0 <= end + 1 }.last ?? first.down
            return end - lastStrong
        }
        let slack = config.shakeWindowMs / 1000 + config.shakeHangoverMs / 1000 + 0.2
        check(!diffs.isEmpty && median(diffs) >= -0.1 && median(diffs) <= slack,
              String(format: "jerk_shake hold ends %.2f s after the last stroke (median); expected 0 … %.2f", median(diffs), slack))
    }
    for name in ["neutral_still", "aim_slow", "aim_fast", "table_still"] {
        if let r = results[name] { check(r.presses.isEmpty, "\(name) \(r.presses.count) presses; need 0") }
    }
    for name in ["regrip", "put_down_pick_up", "free_play"] {
        if let r = results[name] { check(r.presses.count <= 1, "\(name) \(r.presses.count) presses; need ≤ 1 (listed above)") }
    }
    for name in ["push_screen", "push_screen_old", "pull_self", "pull_self_old", "twist_cw", "twist_ccw", "jerk_up", "bow"] {
        if let r = results[name] { check(r.presses.isEmpty, "\(name) \(r.presses.count) LMB presses; need 0") }
    }
    // A take's own gesture must be found ≥ 23 times and nothing else more than once. Both recordings of pull count.
    // The push takes (a push does nothing now) and the jerk_up / bow takes are checked below; absent takes are skipped.
    func countOf(_ r: TakeResult, _ labels: [String]) -> Int { r.marks.filter { labels.contains($0.label) }.count }
    let own: [(take: String, label: String, others: [String])] = [
        ("jerk_up", "jerk_up", ["jerk_down", "pull", "bow_shot", "twist"]),
        ("pull_self", "pull", ["jerk_down", "jerk_up", "bow_shot", "twist"]), ("pull_self_old", "pull", ["jerk_down", "jerk_up", "bow_shot", "twist"]),
        ("twist_cw", "twist", ["jerk_down", "jerk_up", "pull", "bow_shot"]), ("twist_ccw", "twist", ["jerk_down", "jerk_up", "pull", "bow_shot"])]
    for o in own {
        guard let r = results[o.take] else { continue }
        let found = countOf(r, [o.label]), wrong = countOf(r, o.others)
        check(found >= 23 && wrong <= 1, "\(o.take) \(o.label) \(found) detected (need ≥ 23 of 25), \(wrong) wrong gestures (need ≤ 1)")
    }
    for name in ["push_screen", "push_screen_old"] {
        if let r = results[name] {
            let n = countOf(r, ["jerk_down", "jerk_up", "pull", "bow_shot", "twist", "rmb_down"])
            check(n == 0, "\(name) \(n) gestures or RMB presses (a push does nothing); need 0")
        }
    }
    if let r = results["jerk_up"] {
        check(countOf(r, ["rmb_down"]) == countOf(r, ["jerk_up"]), "jerk_up \(countOf(r, ["rmb_down"])) RMB presses for \(countOf(r, ["jerk_up"])) jerk_up gestures; need equal")
    }
    // bow take: 10 × (pull, aim, jerk up). Each pull latches, each jerk up releases once with no extra click.
    if let r = results["bow"] {
        let (latches, releases, shots, clicks) = (countOf(r, ["rmb_down"]), countOf(r, ["rmb_up"]), countOf(r, ["bow_shot"]), countOf(r, ["jerk_up"]))
        check(latches == 10 && releases == 10 && shots == 10 && clicks == 0,
              "bow \(latches) latches (need 10), \(releases) releases (need 10), \(shots) bow shots (need 10), \(clicks) extra RMB clicks (need 0)")
    }
    // Nothing but LMB clicks and shakes may come from the jerk_down and jerk_shake takes: no RMB at all.
    for name in ["jerk_down", "jerk_shake", "twist_cw", "twist_ccw"] {
        if let r = results[name] { check(countOf(r, ["rmb_down", "jerk_up", "pull", "bow_shot"]) == 0, "\(name) \(countOf(r, ["rmb_down", "jerk_up", "pull", "bow_shot"])) RMB events; need 0") }
    }
    if let r = results["twist_cw"] {
        check(countOf(r, ["scroll+1"]) >= 23 && countOf(r, ["scroll-1"]) == 0, "twist_cw scrolls +1: \(countOf(r, ["scroll+1"])), -1: \(countOf(r, ["scroll-1"])); need all +")
    }
    if let r = results["twist_ccw"] {
        check(countOf(r, ["scroll-1"]) >= 23 && countOf(r, ["scroll+1"]) == 0, "twist_ccw scrolls -1: \(countOf(r, ["scroll-1"])), +1: \(countOf(r, ["scroll+1"])); need all -")
    }
    for name in ["neutral_still", "aim_slow", "aim_fast", "table_still"] {
        if let r = results[name] {
            let n = countOf(r, ["jerk_down", "jerk_up", "pull", "bow_shot", "twist", "rmb_down"])
            check(n == 0, "\(name) \(n) clicks/scrolls/latches (pause/resume: \(countOf(r, ["pause"]))/\(countOf(r, ["resume"]))); need 0")
        }
    }
    for name in ["regrip", "put_down_pick_up", "free_play"] {
        if let r = results[name] {
            let n = countOf(r, ["jerk_down", "jerk_up", "pull", "bow_shot", "twist", "rmb_down"])
            check(n <= 1, "\(name) \(n) gestures (need ≤ 1, listed above); pause/resume: \(countOf(r, ["pause"]))/\(countOf(r, ["resume"]))")
        }
    }
    // Residuals come from the takes that record the gesture. bow_shot is taken from wherever it occurs (the bow take, when present).
    var byGesture: [String: [Double]] = [:]
    for (name, r) in results {
        for (g, v) in r.residualsByGesture where g == "bow_shot" || ["jerk_up", "pull_self", "twist_cw", "twist_ccw"].contains(name) { byGesture[g, default: []] += v }
    }
    for g in ["jerk_up", "pull", "bow_shot", "twist"] {
        guard let res = byGesture[g], !res.isEmpty else { continue }
        check(median(res) < 0.5 && res.max()! < 2, String(format: "%@ camera residual: median %.2f° (< 0.5), max %.2f° (< 2) over %d", g as NSString, median(res), res.max()!, res.count))
    }
    for name in ["jerk_down", "jerk_shake"] {
        guard let res = results[name]?.residuals, !res.isEmpty else { continue }
        check(median(res) < 0.5 && res.max()! < 2,
              String(format: "%@ camera residual per gesture: median %.2f° (< 0.5), max %.2f° (< 2) over %d", name as NSString, median(res), res.max()!, res.count))
    }
}
