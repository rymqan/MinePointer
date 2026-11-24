import Foundation

// The link between the UI app and its engine child (`MinePointer --engine`): one line per message.
// Engine → UI on the child's stdout: "@state", "@prompt", "@gesture", "@calibrated", "@error" lines, tab-separated; any other line
// is a log line. UI → engine on the child's stdin: EngineCommand raw values. The engine quits (all buttons released) on stdin EOF.

/// What the UI shows: the session text, the mode and the held buttons, the last gesture (a new seq shows it again).
struct EngineState: Equatable {
    var session = ""        // CaseSession's short state ("waiting: open the case lid", "streaming", ...)
    var mode = ""           // "" while playing; otherwise calibrating, output off, reconnecting, no stream, paused
    var left = false, right = false
    var gesture = ""        // the last recognized gesture, for the panel
    var seq = 0

    /// The indicator panel text: mode · held buttons · recent gesture, or a dot while idle.
    func text(showGesture: Bool) -> String {
        var parts: [String] = []
        if !mode.isEmpty { parts.append(mode) }
        let held = [left ? "LMB" : nil, right ? "RMB" : nil].compactMap { $0 }
        if !held.isEmpty { parts.append(held.joined(separator: "+")) }
        if showGesture, !gesture.isEmpty { parts.append(gesture) }
        return parts.isEmpty ? "●" : parts.joined(separator: " · ")
    }
}

/// Gesture ids in "@gesture" lines, for the setup window's gesture check.
enum EngineGesture: String, CaseIterable {
    case jerkDown, shake, jerkUp, pull, bowShot, twistNext, twistPrevious, veto, pause, resume
}

enum EngineMessage: Equatable {
    case state(EngineState)
    case prompt(String)                 // a calibration step to show large
    case gesture(EngineGesture)
    case calibrated
    case error(String)                  // fatal: the engine exits after it; the text names the cause and the next step
    case log(String)

    init(line: String) {
        let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        switch p[0] {
        case "@state" where p.count == 7:
            guard let seq = Int(p[6]) else { self = .log(line); return }
            self = .state(EngineState(session: p[1], mode: p[2], left: p[3] == "1", right: p[4] == "1", gesture: p[5], seq: seq))
        case "@prompt" where p.count == 2: self = .prompt(p[1])
        case "@gesture" where p.count == 2:
            guard let g = EngineGesture(rawValue: p[1]) else { self = .log(line); return }
            self = .gesture(g)
        case "@calibrated" where p.count == 1: self = .calibrated
        case "@error" where p.count == 2: self = .error(p[1])
        default: self = .log(line)
        }
    }

    var line: String {
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        switch self {
        case .state(let s):
            return ["@state", clean(s.session), clean(s.mode), s.left ? "1" : "0", s.right ? "1" : "0", clean(s.gesture), String(s.seq)]
                .joined(separator: "\t")
        case .prompt(let text): return "@prompt\t" + clean(text)
        case .gesture(let g): return "@gesture\t" + g.rawValue
        case .calibrated: return "@calibrated"
        case .error(let text): return "@error\t" + clean(text)
        case .log(let text): return clean(text)
        }
    }
}

enum EngineCommand: String {
    case recalibrate
    case outputOn = "output on"
    case outputOff = "output off"
    case quit
}

let engineErrorTextAccessibility = "Accessibility is not granted: allow MinePointer in System Settings → Privacy & Security → Accessibility"

/// The `@error` text for a session that ended: CaseSession's reason plus what to do next. AirPointer's own failure texts already say it.
func engineErrorText(_ reason: String) -> String {
    switch reason {
    case ClosedCaseAirPods.bluetoothDenied: return "Bluetooth is not granted: allow MinePointer in System Settings → Privacy & Security → Bluetooth and try again"
    case "AirPods not found": return "AirPods not found: pair them in Bluetooth settings and try again"
    case "AirPods Pro 1 are not supported": return reason + ": use AirPods 4 or another supported model and try again"
    case "could not save the AirPods choice": return reason + ": check the disk space and try again"
    case "the lid was not opened within 120 s": return reason + ": open the case lid and start again"
    case "stopped", "AirPods disconnected": return "The AirPods stream ended (\(reason)): open and close the case lid and start again"
    case let r where r.hasSuffix("is missing from the app bundle"): return reason + ": reinstall MinePointer"
    default: return reason
    }
}

/// Read-merge-write of config.json, the one writer for both processes (the UI's settings, the engine's calibration): sets the
/// given snake_case keys and keeps every other key. An exclusive lock on config.json.lock makes the two processes take turns,
/// the atomic write means a reader never sees half a file, and a file that is there but unreadable is left alone (throws)
/// rather than replaced by the changed keys alone. The engine's ConfigWatcher picks the change up within a second.
func updateConfigFile(_ changes: [String: Any], at url: URL = configURL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lock = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
    guard lock >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { close(lock) }       // closing releases the lock
    flock(lock, LOCK_EX)
    var dict: [String: Any] = [:]
    if let data = try? Data(contentsOf: url) {
        guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        dict = existing
    }
    dict.merge(changes) { _, new in new }
    let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: url, options: .atomic)
}

func engineLinkSelfTest() {
    var s = EngineState(session: "streaming", mode: "paused", left: true, right: false, gesture: "LMB click", seq: 7)
    precondition(EngineMessage(line: EngineMessage.state(s).line) == .state(s), "state round trip")
    precondition(s.text(showGesture: true) == "paused · LMB · LMB click" && s.text(showGesture: false) == "paused · LMB")
    s.right = true; s.mode = ""
    precondition(s.text(showGesture: false) == "LMB+RMB" && EngineState().text(showGesture: true) == "●")
    precondition(EngineMessage(line: EngineMessage.prompt("a\tb").line) == .prompt("a b"), "tabs in text must not split the line")
    precondition(EngineMessage(line: "@gesture\ttwistNext") == .gesture(.twistNext))
    precondition(EngineMessage(line: "@gesture\tnope") == .log("@gesture\tnope"))
    precondition(EngineMessage(line: "@state\tx") == .log("@state\tx") && EngineMessage(line: "[12:00] hello") == .log("[12:00] hello"))
    precondition(EngineMessage(line: "@calibrated") == .calibrated && EngineMessage(line: "@error\tno AirPods") == .error("no AirPods"))
    precondition(EngineCommand(rawValue: "output off") == .outputOff && EngineCommand(rawValue: "quit") == .quit && EngineCommand(rawValue: "nope") == nil)
    precondition(engineErrorText("AirPods not found").hasPrefix("AirPods not found: pair them"))
    precondition(engineErrorText(ClosedCaseAirPods.bluetoothDenied).contains("Privacy & Security → Bluetooth"))
    precondition(engineErrorText("ClosedCaseMotion is missing from the app bundle").hasSuffix("reinstall MinePointer"))
    precondition(engineErrorText("Your AirPods didn’t answer. Connect again.") == "Your AirPods didn’t answer. Connect again.")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("minepointer-link-test.json")
    try? #"{"gain": 5, "neutral_up": [0, 1, 0]}"#.data(using: .utf8)!.write(to: tmp)
    try! updateConfigFile(["gain": 2.5, "invert_y": true], at: tmp)
    let c = Config.load(from: tmp)
    precondition(c.gain == 2.5 && c.invertY && c.neutralUp == [0, 1, 0], "settings writes must keep the calibration keys")
    try? "{\"gain\": 5".data(using: .utf8)!.write(to: tmp)
    precondition((try? updateConfigFile(["gain": 1], at: tmp)) == nil, "an unreadable config.json must not be replaced")
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: tmp.path + ".lock"))
    try? FileManager.default.removeItem(at: tmp)
    print("PASS: engine link lines, config update")
}
