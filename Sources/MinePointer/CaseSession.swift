import AppKit

// Runs AirPointer's closed-case motion helper for the paired AirPods and hands the parsed samples to the app.
// It follows Sources/AirPointer/Session/ClosedCaseSession.swift (ClosedCaseSession.start,
// waitForLid, launch, launchHelper, tick, renewSessionLease, readStatus, stop, finished, shutdown) step by step.
// Left out on purpose: AudioOutputGuard and silent audio, the JavaScript sensor fusion, pointer and tap code.

// MARK: - Pure helpers

enum ReconnectAction: Equatable { case exit, retryNow, waitForLid }

/// What to do when a session ends (helper exit codes: CaseSustainedRenewal.m header). 43 MOTION_STALE is the earbud's 30 min
/// cutoff (two sessions streamed exactly 1802 s, then 43) or a stall: only an open and close of the lid resets it. Transient
/// link or protocol failures get one immediate retry first (the caller falls back to the lid). 52 SIGNALED without our stop
/// request means the helper was killed from outside. Setup errors (not paired, private API missing, wrong model, our lease or
/// pipe) and a stop the app asked for end the app as before; so does nil (Bluetooth denied, AirPods not found).
/// No status (the restore step failed or timed out, AirPods not found) ends the app at startup, but once a stream has worked
/// (`streamed`) it is treated like a drop: wait for the lid.
func reconnectAction(status: Int32?, requested: Bool, streamed: Bool) -> ReconnectAction {
    guard !requested else { return .exit }
    guard let status else { return streamed ? .waitForLid : .exit }
    switch status {
    case 43: return .waitForLid
    case 26, 27, 28, 30, 31, 35, 36, 40, 41, 42, 44, 45, 46, 52: return .retryNow
    default: return .exit
    }
}

/// Copied from ClosedCaseSession.swift (AirPointer, MIT): the in-case reports of status.json's earbud_state_events.
func closedCaseInCaseReports(_ value: Any?) -> [(uptime: Double, primary: Int, secondary: Int)] {
    (value as? [[String: Any]] ?? []).compactMap { report in
        guard let uptime = report["received_uptime"] as? Double,
              let primary = report["primary_code"] as? Int,
              let secondary = report["secondary_code"] as? Int else { return nil }
        return (uptime, primary, secondary)
    }
}

/// Copied from ClosedCaseSession.swift (AirPointer, MIT): true when the paired in-case reports say the lid is closed.
func closedCaseLidClosed(_ reports: [(uptime: Double, primary: Int, secondary: Int)]) -> Bool {
    var closed = false
    var index = 0
    while index < reports.count {
        let report = reports[index]
        if report.primary == 3 || report.secondary == 3 {
            closed = true
        } else if index + 1 < reports.count, report.primary == 2, report.secondary == 2,
                  reports[index + 1].primary == 2, reports[index + 1].secondary == 2,
                  reports[index + 1].uptime - report.uptime <= 0.5 {
            closed.toggle()
            index += 2
            continue
        }
        index += 1
    }
    return closed
}

/// Copied from ClosedCaseSession.swift (AirPointer, MIT): is the status report recent and are both sensors alive.
func closedCaseConnectionFresh(reportAge: Double, sensorAges: [Double], motionAge: Double) -> Bool {
    reportAge >= 0 && reportAge < 2 && sensorAges.count == 2 &&
        (motionAge < 0.5 || sensorAges.allSatisfy { $0 >= 0 && $0 + reportAge < 1 })
}

/// The body of app-lease.txt. The helper exits with 50 when this file is older than 5 s.
func caseLeaseText(_ uptime: Double) -> String {
    String(format: "%.6f\n", uptime)
}

/// Keeps the newest `count` session folders (UUID-named directories) in `root`, deletes the rest.
func pruneSessionFolders(in root: URL, keeping count: Int) {
    let keys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
    func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
    let sessions = entries.filter {
        UUID(uuidString: $0.lastPathComponent) != nil
            && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    for folder in sessions.sorted(by: { created($0) > created($1) }).dropFirst(max(0, count)) {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Cuts a byte stream that arrives in arbitrary pieces into complete lines. A partial last line waits for its newline.
struct LineSplitter {
    private var pending = Data()
    static let limit = 65536

    mutating func feed(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let end = pending.firstIndex(of: 10) {
            let line = pending.prefix(upTo: end)
            pending.removeSubrange(...end)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        // A helper that never sends a newline must not grow the buffer without bound.
        if pending.count > Self.limit { pending.removeAll() }
        return lines
    }
}

/// One read from a non-blocking pipe. Nil when nothing is there right now, or at end of stream.
func readPipeChunk(_ fileDescriptor: Int32) -> Data? {
    var bytes = [UInt8](repeating: 0, count: 32768)
    let count = Darwin.read(fileDescriptor, &bytes, bytes.count)
    return count > 0 ? Data(bytes.prefix(count)) : nil
}

private func appendingHandle(_ url: URL) -> FileHandle? {
    let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard descriptor >= 0 else { return nil }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

// MARK: - Session

final class CaseSession {
    var onSample: ((MotionSample) -> Void)?   // main thread, in arrival order
    var onState: ((String) -> Void)?          // short English state
    var onEnded: ((Int32?, Bool, String) -> Void)?    // helper exit status (nil if it never started), whether shutdown() (app quit) asked to stop, and the failure reason; after cleanup

    static let sessionsFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MinePointer/sessions", isDirectory: true)
    static let helpersFolder = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    static let keptSessions = 5
    static let maxBusyRetries = 3

    private var active = false
    private var stopping = false
    private var token = 0                      // bumped on every start and finish, so stale callbacks do nothing
    private var busyRetries = 0
    private var forceLid = false
    private var shuttingDown = false           // shutdown() only: the internal stop() calls are errors and may reconnect
    private var lidTimeoutEnabled = true
    private var lastState = ""

    private let bluetooth = ClosedCaseBluetoothAccess()
    private var lidWatcher: ClosedCaseLidWatcher?
    private var lidTimeout: Timer?
    private var target: URL { ClosedCaseAirPods.targetURL }

    private var capture: URL?                  // <session folder>/recording, created by the helper
    private var restore: Process?
    private var helper: Process?
    private var stream: FileHandle?
    private var nativeLog: FileHandle?         // <session folder>/native.log: restore output, helper stderr, non-motion lines
    private var helperTxt: FileHandle?         // logs/helper-….txt: every raw stdout line
    private var metaURL: URL?
    private var splitter = LineSplitter()
    private var timer: Timer?
    private var activity: NSObjectProtocol?

    private var startedAt = 0.0
    private var helperStartedAt = 0.0
    private var stoppedAt = 0.0
    private var lastLease = 0.0
    private var lastStatus = 0.0
    private var lastSample = 0.0               // receivedUptime of the newest sample, 0 before the first
    private var connected = false
    private var ready = false
    private var confirmed = false
    private var streaming = false
    private var terminated = false             // helper.terminate() was already sent
    private var feedError: String?

    // MARK: Start

    /// `waitForLid`: go through the lid wait even if the AirPods look connected (after the 30 min cutoff only an open and close
    /// of the lid resets the earbud timer). `lidTimeout`: give up after 120 s; a reconnect waits for as long as it takes.
    func start(waitForLid forceLid: Bool = false, lidTimeout: Bool = true) {
        guard !active else { return }
        self.forceLid = forceLid
        shuttingDown = false
        self.lidTimeoutEnabled = lidTimeout
        active = true
        stopping = false
        busyRetries = 0
        feedError = nil
        token += 1
        let current = token
        emit("requesting Bluetooth access")
        bluetooth.request { [weak self] allowed in
            guard let self, self.active, self.token == current else { return }
            guard allowed else {
                self.finish(ClosedCaseAirPods.bluetoothDenied, status: nil)
                return
            }
            self.choosePair(token: current)
        }
    }

    private func choosePair(token current: Int) {
        emit("looking for paired AirPods")
        ClosedCaseAirPods.survey { [weak self] survey in
            guard let self, self.active, self.token == current else { return }
            let choice = ClosedCaseAirPods.choose(survey, saved: ClosedCaseAirPods.saved)
            guard case .chosen(let pair) = choice else {
                self.finish(choice.failure ?? "AirPods not found", status: nil)
                return
            }
            if pair.usesHeadphoneMotion {
                self.finish("AirPods Pro 1 are not supported", status: nil)
                return
            }
            do {
                try ClosedCaseAirPods.save(pair)
            } catch {
                self.finish("could not save the AirPods choice", status: nil)
                return
            }
            if pair.connected, !self.forceLid {
                self.launch()
            } else {
                self.waitForLid(pair, token: current)
            }
        }
    }

    private func waitForLid(_ pair: ClosedCaseAirPods, token current: Int) {
        emit("waiting: open the case lid")
        lidWatcher = ClosedCaseLidWatcher(productID: pair.productID) { [weak self] in
            guard let self, self.active, self.token == current else { return }
            self.endLidWait()
            self.launch()
        }
        lidWatcher?.start()
        guard lidTimeoutEnabled else { return }
        lidTimeout = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            guard let self, self.active, self.token == current else { return }
            self.endLidWait()
            self.finish("the lid was not opened within 120 s", status: nil)
        }
    }

    private func endLidWait() {
        lidTimeout?.invalidate()
        lidTimeout = nil
        lidWatcher?.stop()
        lidWatcher = nil
    }

    /// Creates the session folder and runs ClosedCaseRestore.bin; its success starts the helper.
    private func launch() {
        let restoreExecutable = Self.helpersFolder.appendingPathComponent("ClosedCaseRestore")
        guard FileManager.default.isExecutableFile(atPath: restoreExecutable.path) else {
            finish("ClosedCaseRestore is missing from the app bundle", status: nil)
            return
        }
        emit("connecting")
        connected = false
        ready = false
        confirmed = false
        streaming = false
        terminated = false
        lastSample = 0
        lastStatus = 0
        lastLease = 0
        splitter = LineSplitter()
        startedAt = uptimeNow()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Receive AirPods motion")
        do {
            pruneSessionFolders(in: Self.sessionsFolder, keeping: Self.keptSessions - 1)
            let folder = Self.sessionsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // The helper creates "recording" itself and fails if it already exists.
            capture = folder.appendingPathComponent("recording", isDirectory: true)
            try renewLease()
            nativeLog = appendingHandle(folder.appendingPathComponent("native.log"))

            let process = Process()
            restore = process
            process.executableURL = restoreExecutable
            process.arguments = [target.path]
            process.standardOutput = nativeLog ?? FileHandle.nullDevice
            process.standardError = nativeLog ?? FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async { self?.restoreExited(process) }
            }
            try process.run()
            scheduleTick(interval: 0.05)
        } catch {
            finish(error.localizedDescription, status: nil)
        }
    }

    private func restoreExited(_ process: Process) {
        guard restore === process else { return }
        restore = nil
        if stopping {
            finish(feedError ?? "stopped", status: nil)
        } else if process.terminationStatus == 0 {
            launchHelper()
        } else {
            finish(ClosedCaseAirPods.restoreFailure(process.terminationStatus), status: nil)
        }
    }

    private func launchHelper() {
        let executable = Self.helpersFolder.appendingPathComponent("ClosedCaseMotion")
        guard FileManager.default.isExecutableFile(atPath: executable.path), let capture else {
            finish("ClosedCaseMotion is missing from the app bundle", status: nil)
            return
        }
        let arguments = [target.path, "--pointer-session", capture.path]
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            finish("could not open the data pipe", status: nil)
            return
        }
        stream = pipe.fileHandleForReading
        openHelperLog(arguments: arguments)

        let process = Process()
        helper = process
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = nativeLog ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { self?.helperExited(process) }
        }
        do {
            helperStartedAt = uptimeNow()
            try process.run()
            // Only the child holds the write end now, so the read end sees end of stream when it exits.
            try? pipe.fileHandleForWriting.close()
            scheduleTick(interval: 0.005)
        } catch {
            try? pipe.fileHandleForWriting.close()
            helper = nil
            finish(error.localizedDescription, status: nil)
        }
    }

    /// logs/helper-YYYYmmdd-HHMMSS.txt and .meta, in the format tools/helper-logger.zsh wrote. Only with record_sessions on.
    private func openHelperLog(arguments: [String]) {
        guard Config.load().recordSessions else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "helper-" + formatter.string(from: Date())
        try? FileManager.default.createDirectory(at: logsFolder, withIntermediateDirectories: true)
        helperTxt = appendingHandle(logsFolder.appendingPathComponent(name + ".txt"))
        let meta = logsFolder.appendingPathComponent(name + ".meta")
        metaURL = meta
        let line = "start \(Int(Date().timeIntervalSince1970)) args \(arguments.joined(separator: " "))\n"
        try? Data(line.utf8).write(to: meta)
    }

    // MARK: Tick

    private func scheduleTick(interval: TimeInterval) {
        timer?.invalidate()
        let next = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func tick() {
        let now = uptimeNow()
        if !stopping {
            do {
                try renewLease()
            } catch {
                feedError = "could not write the session lease"
                stop()
                return
            }
        }
        if restore?.isRunning == true, now - startedAt > 30 {
            feedError = "AirPods did not connect: open the lid and wake one earbud"
            stop()
            return
        }
        if !stopping, helper?.isRunning == true, !confirmed, lastSample == 0, now - helperStartedAt > 20 {
            feedError = "no data arrived: open the lid and wake one earbud"
            stop()
            return
        }
        if stopping, stoppedAt > 0, now - stoppedAt > 3 {
            // The helper did not leave after "stop"; ask once more with a signal.
            if !terminated, helper?.isRunning == true {
                terminated = true
                helper?.terminate()
            }
            return
        }
        if now - lastStatus >= 0.1 {
            lastStatus = now
            readStatus()
        }
        if helper != nil { readMotion() }
        if feedError != nil, !stopping { stop() }
    }

    /// Writes the lease at most once per second. The helper exits with 50 if it is older than 5 s.
    private func renewLease() throws {
        guard let capture else { return }
        let now = uptimeNow()
        guard now - lastLease >= 1 else { return }
        let url = capture.deletingLastPathComponent().appendingPathComponent("app-lease.txt")
        try Data(caseLeaseText(now).utf8).write(to: url, options: .atomic)
        lastLease = now
    }

    // MARK: Status

    private func readStatus() {
        guard let capture,
              let data = try? Data(contentsOf: capture.appendingPathComponent("status.json")),
              let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let snapshot = state["case_snapshot"] as? [String: Any],
              let sensors = state["sensors"] as? [[String: Any]] else { return }
        let reportAge = Date().timeIntervalSince1970 - (state["updated_unix"] as? Double ?? 0)
        connected = closedCaseConnectionFresh(
            reportAge: reportAge,
            sensorAges: sensors.map { $0["age_seconds"] as? Double ?? 100 },
            motionAge: uptimeNow() - lastSample)
        ready = !stopping && !confirmed && connected
            && state["open_baseline_verified"] as? Bool == true
            && snapshot["root_identity_verified"] as? Bool == true
        if ready, helper?.isRunning == true,
           closedCaseLidClosed(closedCaseInCaseReports(state["earbud_state_events"])) {
            confirmClosed()
        }
        if let error = snapshot["error"] as? String, !error.isEmpty, feedError == nil {
            logNative("helper error: \(error)")
            feedError = "helper error: \(error)"
            emit(feedError ?? "")
            return
        }
        if confirmed {
            emit(streaming ? "streaming" : "lid closed")
        } else if ready {
            emit("ready: close the lid")
        } else if helper != nil {
            emit("connecting")
        }
    }

    /// Tells the helper the lid is closed. Runs once per helper launch.
    private func confirmClosed() {
        guard !confirmed, let capture else { return }
        do {
            try Data("closed_confirmed\n".utf8).write(to: capture.appendingPathComponent("phase.txt"), options: .atomic)
            confirmed = true
            ready = false
            logNative(String(format: "STEP lid closed uptime=%.3f", uptimeNow()))
        } catch {
            feedError = "could not write phase.txt"
        }
    }

    // MARK: Motion

    private func readMotion() {
        guard let stream else { return }
        while let chunk = readPipeChunk(stream.fileDescriptor) {
            try? helperTxt?.write(contentsOf: chunk)
            for line in splitter.feed(chunk) {
                if let sample = MotionSample(helperLine: line[...]) {
                    lastSample = sample.receivedUptime
                    if confirmed { streaming = true }
                    onSample?(sample)
                } else {
                    logNative(line)
                }
            }
        }
    }

    private func logNative(_ text: String) {
        try? nativeLog?.write(contentsOf: Data((text + "\n").utf8))
    }

    // MARK: Exit

    private func helperExited(_ process: Process) {
        guard helper === process else { return }
        readMotion()          // what the helper wrote just before it exited
        readStatus()
        let status: Int32? = process.terminationReason == .exit ? process.terminationStatus : nil
        // The old wrapper recorded a shell exit code, 128 + signal for a killed helper.
        let code = status ?? (128 + process.terminationStatus)
        if let metaURL, let handle = try? FileHandle(forWritingTo: metaURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("exit \(code) end \(Int(Date().timeIntervalSince1970))\n".utf8))
            try? handle.close()
        }
        closeHelperFiles()
        helper = nil

        if status == 25, !stopping, busyRetries < Self.maxBusyRetries {
            // CHANNEL_BUSY: another app held the AirPods' control channel. Try again.
            busyRetries += 1
            timer?.invalidate()
            timer = nil
            emit("AirPods busy, retry \(busyRetries) of \(Self.maxBusyRetries)")
            let current = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.active, self.token == current, !self.stopping else { return }
                self.launch()
            }
            return
        }
        let reason = ClosedCaseAirPods.helperFailure(status, stopping: stopping)
            ?? feedError
            ?? (stopping ? "stopped" : "AirPods disconnected")
        finish(reason, status: status ?? code)
    }

    /// `calib <receivedUptime> up x y z forward x y z` in the .meta: the axes of the grip from this point on (replay reads them).
    func recordCalibration(up: [Double], forward: [Double]) {
        guard let metaURL, let handle = try? FileHandle(forWritingTo: metaURL) else { return }
        _ = try? handle.seekToEnd()
        func text(_ v: [Double]) -> String { v.map { String(format: "%.3f", $0) }.joined(separator: " ") }
        try? handle.write(contentsOf: Data(String(format: "calib %.6f up %@ forward %@\n", lastSample, text(up), text(forward)).utf8))
        try? handle.close()
    }

    private func closeHelperFiles() {
        try? stream?.close()
        stream = nil
        try? helperTxt?.close()
        helperTxt = nil
        metaURL = nil
    }

    private func finish(_ reason: String, status: Int32?) {
        guard active else { return }
        let requested = shuttingDown
        active = false
        stopping = false
        token += 1
        endLidWait()
        timer?.invalidate()
        timer = nil
        closeHelperFiles()
        try? nativeLog?.close()
        nativeLog = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        restore = nil
        helper = nil
        capture = nil
        connected = false
        ready = false
        confirmed = false
        lastState = ""
        emit("session ended: \(reason)")
        onEnded?(status, requested, reason)
    }

    // MARK: Stop

    /// Asks the helper to clean up (phase.txt "stop") and returns at once; onEnded follows when it has exited.
    func stop() {
        guard active, !stopping else { return }
        stopping = true
        ready = false
        stoppedAt = uptimeNow()
        if let capture {
            try? Data("stop\n".utf8).write(to: capture.appendingPathComponent("phase.txt"), options: .atomic)
        }
        if restore?.isRunning == true {
            restore?.terminate()      // restoreExited finishes the session
        } else if helper == nil, restore == nil {
            // Still choosing AirPods or waiting for the lid: nothing to clean up.
            finish(feedError ?? "stopped", status: nil)
        }
        // With a helper running, helperExited finishes the session; tick() sends SIGTERM after 3 s.
    }

    /// For app termination (SIGINT, SIGTERM): stops and spins the main run loop until the helper has cleaned up, up to 7 s.
    func shutdown() {
        shuttingDown = true
        stop()
        let deadline = Date().addingTimeInterval(7)
        while active, deadline.timeIntervalSinceNow > 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if helper?.isRunning == true { helper?.terminate() }
    }

    private func emit(_ state: String) {
        guard state != lastState else { return }
        lastState = state
        onState?(state)
    }
}

// MARK: - Self-test

func caseSessionSelfTest() {
    // Lines split across partial pipe reads, including a multi-byte character cut in half.
    var splitter = LineSplitter()
    precondition(splitter.feed(Data("1,11,100".utf8)).isEmpty)
    precondition(splitter.feed(Data("0000,1.5,1,2,3\nEarbud Model".utf8)) == ["1,11,1000000,1.5,1,2,3"])
    precondition(splitter.feed(Data("Name=x\n\n2,12,".utf8)) == ["Earbud ModelName=x"])
    let accent = Array("é\n".utf8)
    precondition(splitter.feed(Data([UInt8]([0x33]) + [accent[0]])).isEmpty)
    precondition(splitter.feed(Data([accent[1], accent[2]])) == ["2,12,3é"])
    var endless = LineSplitter()
    precondition(endless.feed(Data(repeating: 65, count: 70000)).isEmpty)
    precondition(endless.feed(Data("ok\n".utf8)) == ["ok"])
    precondition(MotionSample(helperLine: "80989,11,245310775,155195.959665458,82481,14604,54960"[...]) != nil)

    // Lid detection on report arrays, the same timelines AirPointer checks.
    func lid(_ timeline: [(Double, Int, Int)]) -> Bool {
        closedCaseLidClosed(timeline.map { (uptime: $0.0, primary: $0.1, secondary: $0.2) })
    }
    let closedOnce: [(Double, Int, Int)] = [(0, 2, 2), (4.6, 2, 2), (4.7, 2, 2)]
    let closedTwice: [(Double, Int, Int)] = [(0, 2, 2), (1.1, 2, 2), (1.2, 2, 2), (2.3, 2, 2), (2.4, 2, 2),
                                             (12.8, 2, 2), (12.9, 2, 2), (16.7, 2, 3)]
    let budLifted: [(Double, Int, Int)] = [(0, 2, 2), (2.8, 1, 2), (2.9, 1, 2), (3.1, 2, 2), (4.7, 2, 2),
                                           (4.7, 2, 2), (8.7, 2, 3)]
    precondition(!lid([]))
    precondition(!lid(Array(closedOnce.prefix(2))))
    precondition(lid(closedOnce))
    precondition(!lid([(0, 2, 2), (4.6, 2, 2), (5.4, 2, 2)]))
    precondition(lid(Array(closedTwice.prefix(3))))
    precondition(!lid(Array(closedTwice.prefix(5))))
    precondition(lid(Array(closedTwice.prefix(7))))
    precondition(lid(closedTwice))
    precondition(!lid(Array(budLifted.prefix(5))))
    precondition(lid(Array(budLifted.prefix(6))))
    precondition(lid([(0, 2, 2), (9, 2, 3)]))
    let json = #"[{"received_uptime":1.5,"primary_code":2,"secondary_code":2,"source_opcode":6},{"primary_code":2}]"#
    let reported = try? JSONSerialization.jsonObject(with: Data(json.utf8))
    precondition(closedCaseInCaseReports(reported).count == 1)
    precondition(closedCaseInCaseReports(nil).isEmpty)
    precondition(closedCaseConnectionFresh(reportAge: 1.05, sensorAges: [0.01, 0.02], motionAge: 0.01))
    precondition(!closedCaseConnectionFresh(reportAge: 3, sensorAges: [0, 0], motionAge: 0.01))

    // Lease text.
    precondition(caseLeaseText(1234.5) == "1234.500000\n")
    precondition(caseLeaseText(0.0000004) == "0.000000\n")

    // Pruning keeps the newest sessions and leaves other folders alone.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("minepointer-prune-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    var made: [URL] = []
    for index in 0..<4 {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? (folder as NSURL).setResourceValue(Date(timeIntervalSince1970: Double(1_000_000 + index * 60)), forKey: .creationDateKey)
        made.append(folder)
    }
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    pruneSessionFolders(in: root, keeping: 2)
    let left = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    precondition(left == Set([made[2].lastPathComponent, made[3].lastPathComponent, "notes"]))
    pruneSessionFolders(in: root.appendingPathComponent("missing"), keeping: 2)   // must not crash

    precondition(reconnectAction(status: 43, requested: false, streamed: false) == .waitForLid)
    precondition(reconnectAction(status: 44, requested: false, streamed: false) == .retryNow && reconnectAction(status: 41, requested: false, streamed: false) == .retryNow)
    precondition(reconnectAction(status: 52, requested: false, streamed: false) == .retryNow && reconnectAction(status: 52, requested: true, streamed: false) == .exit)
    precondition(reconnectAction(status: 43, requested: true, streamed: false) == .exit && reconnectAction(status: nil, requested: false, streamed: false) == .exit)
    precondition(reconnectAction(status: nil, requested: false, streamed: true) == .waitForLid && reconnectAction(status: nil, requested: true, streamed: true) == .exit)
    precondition([22, 23, 24, 32, 34, 50, 51, 53, 0].allSatisfy { reconnectAction(status: $0, requested: false, streamed: false) == .exit })
    print("PASS: case session line splitting, lid detection, lease text, session pruning, reconnect decision")
}
