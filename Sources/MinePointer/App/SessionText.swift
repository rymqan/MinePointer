import Foundation

// The engine's raw strings (CaseSession's short states, the modes of EngineState) as short sentences for a person.

enum SessionText {
    /// A CaseSession state in plain words. Unknown text (an error from the session) passes through.
    static func session(_ raw: String) -> String {
        switch raw {
        case "": return "Starting…"
        case "requesting Bluetooth access": return "Waiting for Bluetooth access"
        case "looking for paired AirPods": return "Looking for your AirPods"
        case "waiting: open the case lid": return "Open and close the case lid"
        case "connecting": return "Connecting to your AirPods"
        case "streaming": return "Connected"
        case "lid closed": return "Lid closed, waiting for motion"
        case "ready: close the lid": return "Close the case lid"
        default:
            if raw.hasPrefix("AirPods busy, retry "), let n = raw.split(separator: " ").dropFirst(3).first {
                return "AirPods busy, trying again (\(n))"
            }
            if raw.hasPrefix("session ended: ") { return "Session ended (\(raw.dropFirst(15)))" }
            return raw
        }
    }

    /// An EngineState.mode in plain words; "" while playing.
    static func mode(_ raw: String) -> String {
        switch raw {
        case "calibrating": return "Calibrating"
        case "output off": return "Output off"
        case "reconnecting": return "Reconnecting"
        case "no stream": return "No motion from the case"
        case "paused": return "Paused (case flat)"
        default: return raw
        }
    }

    /// The menu's status row: the mode when there is one, else the session.
    static func line(_ state: EngineState) -> String {
        let mode = Self.mode(state.mode)
        if mode.isEmpty { return session(state.session) }
        return state.session == "streaming" ? mode : "\(mode) · \(session(state.session))"
    }

    /// A calibration prompt for a page that already says it is calibrating: without the engine's "Calibration: " prefix.
    static func prompt(_ raw: String) -> String {
        guard raw.hasPrefix("Calibration: ") else { return raw }
        let rest = raw.dropFirst(13)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// True while the session waits for the person to open the lid.
    static func waitsForLid(_ raw: String) -> Bool { raw == "waiting: open the case lid" }
}
