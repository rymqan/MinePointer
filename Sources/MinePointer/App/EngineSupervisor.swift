import CoreGraphics
import Foundation

// Runs the engine (`MinePointer --engine`) as a child, parses its stdout (EngineLink.swift), keeps the log and decides
// whether to restart it. MINEPOINTER_ENGINE=<path> replaces the executable, with no arguments (a fake engine for UI tests).

enum EngineStatus: Equatable {
    case stopped
    case running
    case failed(String)         // the engine reported an @error and exited; the text names the cause and the next step
    case crashLoop              // it kept dying without saying why
}

enum EngineExitAction: Equatable {
    case none                   // a requested stop
    case restart
    case failed(String)
    case crashLoop
}

enum EngineEvent {
    case status                 // EngineSupervisor.status changed
    case message(EngineMessage) // one parsed line from the engine (log lines included)
}

/// What to do when the engine exits. `restarts` are the uptimes of the earlier automatic restarts.
func engineExitAction(requested: Bool, error: String?, restarts: [Double], now: Double,
                      limit: Int = EngineSupervisor.restartLimit, window: Double = EngineSupervisor.restartWindow) -> EngineExitAction {
    if requested { return .none }
    if let error { return .failed(error) }
    return restarts.filter { now - $0 < window }.count >= limit ? .crashLoop : .restart
}

final class EngineSupervisor {
    static let restartLimit = 3             // automatic restarts ...
    static let restartWindow = 120.0        // ... within this many seconds
    static let restartDelay = 1.0
    static let stopGrace = 3.0              // after `quit`, then terminate()
    static let logKept = 300
    static let logLimit = 5_000_000         // engine.log is renamed to engine.1.log above this, when the supervisor is created

    static var logURL: URL { logsFolder.appendingPathComponent("engine.log") }

    private(set) var status = EngineStatus.stopped
    private(set) var state = EngineState()
    private(set) var logLines: [String] = []
    /// While true the engine gets `output off` as soon as it runs (setup must not receive synthetic clicks).
    var holdOutputOff = false
    /// The output state the person chose (menu, panic key, setup); an automatic restart gets it back before it can click.
    private var outputOff = false

    private var observers: [(EngineEvent) -> Void] = []
    private var process: Process?
    private var input: FileHandle?
    private var pipes: [Pipe] = []            // a Pipe closes its descriptors when it is released, so they live as long as the child
    private var generation = 0
    private var requested = false
    private var sawError: String?
    private var restarts: [Double] = []
    private var restartTimer: Timer?
    private var startWhenStopped = false
    private var stopCompletions: [() -> Void] = []
    private var logHandle: FileHandle?
    private var sentOutputOff = false

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: logsFolder, withIntermediateDirectories: true)
        let size = (try? fm.attributesOfItem(atPath: Self.logURL.path))?[.size] as? Int ?? 0
        if size > Self.logLimit {
            let old = logsFolder.appendingPathComponent("engine.1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: Self.logURL, to: old)
        }
    }

    func observe(_ handler: @escaping (EngineEvent) -> Void) { observers.append(handler) }

    /// True until the child has really exited, also while it shuts down.
    var hasProcess: Bool { process != nil }

    // MARK: start and stop

    /// A start by the person: forgets earlier crashes.
    func start() {
        if process != nil {
            if requested { startWhenStopped = true }      // the old engine is still shutting down
            return
        }
        restarts = []
        outputOff = false
        launch()
    }

    private func launch() {
        restartTimer?.invalidate(); restartTimer = nil
        requested = false; sawError = nil; sentOutputOff = false
        state = EngineState()
        let override = ProcessInfo.processInfo.environment["MINEPOINTER_ENGINE"]
        guard let executable = override.map({ URL(fileURLWithPath: $0) }) ?? Bundle.main.executableURL else {
            fail("MinePointer could not find its engine. Reinstall the app, then try again.")
            return
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.arguments = override == nil ? ["--engine"] : []
        child.standardInput = stdin
        child.standardOutput = stdout           // stderr stays inherited
        do { try child.run() } catch {
            fail("MinePointer could not start its engine (\(error.localizedDescription)). Try again.")
            return
        }
        generation += 1
        let mine = generation
        process = child; input = stdin.fileHandleForWriting; pipes = [stdin, stdout]
        // The child has its own copies of the other ends; without this, the reader below would never see the end of the stream.
        try? stdout.fileHandleForWriting.close(); try? stdin.fileHandleForReading.close()
        note("engine started (pid \(child.processIdentifier))")
        setStatus(.running)
        if holdOutputOff || outputOff { send(.outputOff); sentOutputOff = true }
        let reader = stdout.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var splitter = LineSplitter()
            while true {
                let data = reader.availableData         // returns what is there, empty at end of stream
                if data.isEmpty { break }
                let lines = splitter.feed(data)
                DispatchQueue.main.async { self?.handle(lines, generation: mine) }
            }
            child.waitUntilExit()
            DispatchQueue.main.async { self?.exited(child, generation: mine) }
        }
        // A child that holds the pipe open after the engine died must not keep us waiting.
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.exited(child, generation: mine) }
        }
    }

    /// Asks the engine to quit (it releases every button), terminates it after the grace period. `completion` runs once it is gone.
    func stop(completion: (() -> Void)? = nil) {
        restartTimer?.invalidate(); restartTimer = nil
        startWhenStopped = false
        guard let child = process else {
            if status != .stopped { setStatus(.stopped) }
            completion?()
            return
        }
        if let completion { stopCompletions.append(completion) }
        guard !requested else { return }
        requested = true
        note("stop requested")
        send(.quit)
        try? input?.close(); input = nil
        setStatus(.stopped)
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopGrace) { [weak self] in
            guard let self, mine == generation, process === child, child.isRunning else { return }
            note("engine did not quit, terminating")
            child.terminate()
            // A suspended or stuck engine cannot run its SIGTERM handler: kill it; exited() then releases the buttons and completes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, mine == generation, process === child, child.isRunning else { return }
                note("engine did not terminate, killing it")
                kill(child.processIdentifier, SIGKILL)
            }
        }
    }

    func send(_ command: EngineCommand) {
        if command == .outputOff { outputOff = true } else if command == .outputOn { outputOff = false }
        guard let input else { return }
        if (try? input.write(contentsOf: Data((command.rawValue + "\n").utf8))) == nil { note("could not send '\(command.rawValue)'") }
    }

    // MARK: engine output and exit

    private func handle(_ lines: [String], generation mine: Int) {
        guard mine == generation else { return }
        for line in lines {
            let message = EngineMessage(line: line)
            switch message {
            case .state(let next):
                state = next
                // The panic key changes output inside the engine; "calibrating" hides the output mode, so it leaves it as it was.
                if next.mode == "output off" { outputOff = true } else if next.mode != "calibrating" { outputOff = false }
                if holdOutputOff || outputOff, !sentOutputOff { send(.outputOff); sentOutputOff = true }
            case .error(let text): sawError = text; note("engine error: \(text)")
            case .log(let text): appendLog(text)
            default: break
            }
            for observer in observers { observer(.message(message)) }
        }
    }

    private func exited(_ child: Process, generation mine: Int) {
        guard mine == generation, process === child else { return }        // the other of the two exit paths already ran
        process = nil; input = nil; pipes = []
        releaseButtons()
        let now = uptimeNow()
        let action = engineExitAction(requested: requested, error: sawError, restarts: restarts, now: now)
        note("engine exited (status \(child.terminationStatus)): \(action)")
        switch action {
        case .none: setStatus(.stopped)
        case .restart:
            restarts.append(now)
            state = EngineState()
            setStatus(.running)
            restartTimer = Timer.scheduledTimer(withTimeInterval: Self.restartDelay, repeats: false) { [weak self] _ in self?.launch() }
        case .failed(let text): setStatus(.failed(text))
        case .crashLoop: setStatus(.crashLoop)
        }
        finishStop()
        if startWhenStopped { startWhenStopped = false; start() }
    }

    /// Mouse-ups for both buttons from the UI process (same bundle, same Accessibility grant): a crashed or killed engine
    /// cannot release what it held, and the next engine starts believing nothing is held. A stray mouse-up is harmless.
    private func releaseButtons() {
        let at = CGEvent(source: nil)?.location ?? .zero
        for (type, button) in [(CGEventType.leftMouseUp, CGMouseButton.left), (.rightMouseUp, .right)] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: button)?.post(tap: .cghidEventTap)
        }
    }

    private func finishStop() {
        let done = stopCompletions
        stopCompletions = []
        for completion in done { completion() }
    }

    private func fail(_ text: String) {
        note(text)
        setStatus(.failed(text))
    }

    private func setStatus(_ next: EngineStatus) {
        guard next != status else { return }
        status = next
        for observer in observers { observer(.status) }
    }

    // MARK: log

    /// A line from the supervisor itself, marked "[ui]" in engine.log.
    func note(_ text: String) {
        appendLog("[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] [ui] \(text)")
    }

    private func appendLog(_ text: String) {
        logLines.append(text)
        if logLines.count > Self.logKept { logLines.removeFirst(logLines.count - Self.logKept) }
        if logHandle == nil {
            if !FileManager.default.fileExists(atPath: Self.logURL.path) { FileManager.default.createFile(atPath: Self.logURL.path, contents: nil) }
            logHandle = try? FileHandle(forWritingTo: Self.logURL)
            _ = try? logHandle?.seekToEnd()
        }
        try? logHandle?.write(contentsOf: Data((text + "\n").utf8))
    }
}
