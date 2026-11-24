import AppKit

// Indicator: held buttons, the last gesture and the mode, in a small panel over the game.
// It runs as a child process (`MinePointer --indicator`): a window needs NSApplication, and macOS wakes a registered background
// app only every ~100 ms while a fullscreen game is frontmost. In the MinePointer process that made the camera choppy; a
// lagging indicator does not matter. Protocol: one tab-separated line per change on the child's stdin
// (left, right as 0/1, mode, gesture, gesture sequence). The child quits when the pipe closes.

private let gestureSeconds = 1.2      // how long the last gesture stays on the panel
private let margin: CGFloat = 12      // from the top right screen corner, outside the cursor clamp area (top 15% of the window)

struct IndicatorState: Equatable {
    var left = false, right = false
    var mode = ""           // "" while playing; otherwise calibrating, output off, reconnecting, no stream, paused
    var gesture = ""        // the last recognized gesture; a new seq shows it again even if the text repeats
    var seq = 0

    init() {}

    init?(line: String) {
        let p = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard p.count == 5, let s = Int(p[4]) else { return nil }
        left = p[0] == "1"; right = p[1] == "1"; mode = String(p[2]); gesture = String(p[3]); seq = s
    }

    var line: String { [left ? "1" : "0", right ? "1" : "0", mode, gesture, String(seq)].joined(separator: "\t") }

    /// The panel text: mode · held buttons · recent gesture, or a dot while idle.
    func text(showGesture: Bool) -> String {
        var parts: [String] = []
        if !mode.isEmpty { parts.append(mode) }
        let held = [left ? "LMB" : nil, right ? "RMB" : nil].compactMap { $0 }
        if !held.isEmpty { parts.append(held.joined(separator: "+")) }
        if showGesture, !gesture.isEmpty { parts.append(gesture) }
        return parts.isEmpty ? "●" : parts.joined(separator: " · ")
    }
}

/// Parent side: starts the child and sends the state when it changes.
final class Indicator {
    private var input: FileHandle?
    private var sent: IndicatorState?

    init?() {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process(), pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--indicator"]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        input = pipe.fileHandleForWriting
    }

    func send(_ state: IndicatorState) {
        guard state != sent, let input else { return }
        sent = state
        // The child died: stop sending (SIGPIPE is ignored in live mode, so the write just fails).
        if (try? input.write(contentsOf: Data((state.line + "\n").utf8))) == nil { self.input = nil }
    }
}

/// Child side: the panel. Never returns.
func runIndicator() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 26), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
    panel.hasShadow = false
    panel.ignoresMouseEvents = true          // a synthetic click must never land here or take focus from the game
    panel.hidesOnDeactivate = false
    panel.level = .screenSaver
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let label = NSTextField(labelWithString: "")     // empty, so the first render lays the panel out
    label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    label.textColor = .white
    panel.contentView?.addSubview(label)

    var state = IndicatorState(), shownSeq = 0, gestureUntil = 0.0
    func render() {
        let text = state.text(showGesture: uptimeNow() < gestureUntil)
        guard text != label.stringValue else { return }
        label.stringValue = text
        let size = label.fittingSize
        label.frame = NSRect(x: 8, y: 4, width: size.width, height: size.height)
        guard let screen = NSScreen.main?.frame else { return }
        let w = size.width + 16, h = size.height + 8
        panel.setFrame(NSRect(x: screen.maxX - w - margin, y: screen.maxY - h - margin, width: w, height: h), display: true)
    }
    render()
    panel.orderFrontRegardless()

    var splitter = LineSplitter()
    FileHandle.standardInput.readabilityHandler = { handle in
        let data = handle.availableData
        DispatchQueue.main.async {
            if data.isEmpty { exit(0) }       // MinePointer quit or crashed
            for line in splitter.feed(data) {
                guard let next = IndicatorState(line: line) else { continue }
                if next.seq != shownSeq { shownSeq = next.seq; gestureUntil = uptimeNow() + gestureSeconds }
                state = next
            }
            render()
        }
    }
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in render() }      // expires the gesture text
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
        label.stringValue = ""; render()
    }
    app.run()
    exit(0)
}

func indicatorSelfTest() {
    var s = IndicatorState()
    precondition(s.text(showGesture: true) == "●")
    s.left = true; s.mode = "paused"; s.gesture = "LMB click"; s.seq = 7
    precondition(IndicatorState(line: s.line) == s, "line round trip")
    precondition(s.text(showGesture: true) == "paused · LMB · LMB click" && s.text(showGesture: false) == "paused · LMB")
    s.right = true; s.mode = ""
    precondition(s.text(showGesture: false) == "LMB+RMB")
    precondition(IndicatorState(line: "1\t0\tx") == nil && IndicatorState(line: "1\t0\t\t\tz") == nil)
    print("PASS: indicator state line and panel text")
}
