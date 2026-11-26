import AppKit

// The app icon the user picks in Settings, and the menu bar template. The icons are built from Packaging/Icon by make-icon.swift.

enum AppIconChoice: String, CaseIterable {
    case green, light, graphite      // green is the bundle's own AppIcon.icns; keep in step with make-icon.swift

    static let configKey = "app_icon"

    static func from(_ raw: Any?) -> AppIconChoice { (raw as? String).flatMap(AppIconChoice.init) ?? .green }
    static var current: AppIconChoice { from(readConfigRaw()[configKey]) }

    var title: String {
        switch self {
        case .green: return "Green"
        case .light: return "Light"
        case .graphite: return "Graphite"
        }
    }

    var image: NSImage? {
        Bundle.main.url(forResource: "AppIcon-\(rawValue)", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }

    /// Shows this icon in Finder and Launchpad by writing a custom icon onto the bundle; green removes it. Returns an error text,
    /// and on failure changes nothing, so the running app never shows an icon that Finder does not.
    /// The custom icon (an `Icon\r` file and a FinderInfo xattr at the bundle root) leaves the signature valid for
    /// `codesign --verify` but not for `--strict`; the designated requirement, which the privacy grants use, does not change.
    @discardableResult
    func apply() -> String? {
        let bundle = Bundle.main.bundleURL
        // a bare binary has no Finder icon
        guard bundle.pathExtension != "app" || NSWorkspace.shared.setIcon(self == .green ? nil : image, forFile: bundle.path, options: []) else {
            return "Finder kept the old icon because macOS did not let MinePointer change its app. Move MinePointer to Applications, open it from there and try again."
        }
        if let image { NSApp.applicationIconImage = image }
        return nil
    }

    /// At launch: an app update replaces the bundle and drops the custom icon, so put the chosen one back. The bundle is written
    /// only when Finder's icon disagrees with the choice (a variant swapped by hand outside Settings is not detected).
    static func restoreAtLaunch() {
        let choice = current
        let hasCustomIcon = FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Icon\r").path)
        if (choice != .green) != hasCustomIcon {
            choice.apply()
        } else if choice != .green, let image = choice.image {
            NSApp.applicationIconImage = image
        }
    }
}

/// The menu bar template: the closed case with the Creeper face cut out (nil in a bare binary without the bundle's resources).
let menuBarTemplate: NSImage? = {
    guard let image = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg").flatMap(NSImage.init(contentsOf:)) else { return nil }
    image.size = NSSize(width: 18, height: 18)
    image.isTemplate = true
    return image
}()
