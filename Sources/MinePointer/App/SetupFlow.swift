import Foundation

// The setup window's logic without any view: which step is showing, what the engine's messages change, what is lit.

enum SetupStep: Int, CaseIterable {
    case welcome = 1, permissions, airpods, connect, calibrate, gestures, done
}

/// What the gesture check shows; several engine gestures can light one tile.
enum GestureTile: CaseIterable {
    case jerkDown, shake, jerkUp, pull, twist, pause

    init?(_ gesture: EngineGesture) {
        switch gesture {
        case .jerkDown: self = .jerkDown
        case .shake: self = .shake
        case .jerkUp, .bowShot: self = .jerkUp
        case .pull: self = .pull
        case .twistNext, .twistPrevious: self = .twist
        case .pause: self = .pause
        case .veto, .resume: return nil
        }
    }

    /// The motion the gesture check demonstrates for this tile.
    var clip: CaseClip {
        switch self {
        case .jerkDown: return .jerkDown
        case .shake: return .shake
        case .jerkUp: return .jerkUp
        case .pull: return .pull
        case .twist: return .twist
        case .pause: return .pause
        }
    }
}

struct SetupPermissions: Equatable {
    var bluetooth = false
    var bluetoothAsked = false        // false while macOS has not asked yet (the button then requests; otherwise it opens Settings)
    var accessibility = false
    var inputMonitoring = false       // recommended for the hotkeys, not required

    var required: Bool { bluetooth && accessibility }
}

struct SetupFlow: Equatable {
    var step = SetupStep.welcome
    var prompt: String?
    var calibrated = false
    var lit: Set<GestureTile> = []
    var vetoes = 0                    // counts up on each refused gesture, so the view can show its hint again

    var picked: GestureTile?          // the tile the person clicked to see its motion

    /// The tile the gesture check demonstrates: the clicked one, else the first one not lit yet, else the first.
    var demoTile: GestureTile { picked ?? GestureTile.allCases.first { !lit.contains($0) } ?? .jerkDown }

    static let calibrationSteps = 3

    /// "Step n of 3" for the calibration prompts of Calibration.swift, nil for any other text.
    static func calibrationNumber(_ prompt: String) -> Int? {
        if prompt.contains("hold the case still") { return 1 }
        if prompt.contains("clockwise twists") { return 2 }
        if prompt.contains("Slowly raise") { return 3 }
        return nil
    }

    /// The motion shown for calibration step 1-3.
    static func calibrationClip(_ step: Int) -> CaseClip? {
        [CaseClip.calibrationStill, .calibrationTwists, .calibrationTilt].dropFirst(step - 1).first
    }

    /// The engine's messages move the flow along: Connect → Calibrate on the first prompt (not on the calibrating mode: the
    /// engine is in it from its start, while it still waits for the lid),
    /// Calibrate → Gestures on @calibrated; @gesture lights tiles on the gesture step only.
    mutating func apply(_ message: EngineMessage) {
        switch message {
        case .state: break
        case .prompt(let text):
            prompt = text
            if step == .connect { step = .calibrate }
        case .calibrated:
            calibrated = true; prompt = nil
            if step == .connect || step == .calibrate { step = .gestures }
        case .gesture(let gesture):
            guard step == .gestures else { return }
            if gesture == .veto { vetoes += 1 } else if let tile = GestureTile(gesture) { lit.insert(tile) }
        case .error, .log, .pose: break
        }
    }

    /// Whether Continue is enabled on the steps that gate it.
    static func canContinue(_ step: SetupStep, permissions: SetupPermissions, hasAirPods: Bool) -> Bool {
        switch step {
        case .permissions: return permissions.required
        case .airpods: return hasAirPods
        default: return true
        }
    }

    /// The step before, for the Back button; the engine steps and the first have none.
    static func back(from step: SetupStep) -> SetupStep? {
        switch step {
        case .permissions, .airpods, .connect: return SetupStep(rawValue: step.rawValue - 1)
        default: return nil
        }
    }
}
