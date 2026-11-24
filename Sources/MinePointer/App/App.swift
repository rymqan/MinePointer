import AppKit
import ApplicationServices
import CoreBluetooth

let setupCompleteKey = "setupComplete"

/// The UI app (menu bar, setup and settings windows); it runs the engine as a child. Never returns.
/// MINEPOINTER_SETUP_STEP=<1-7> opens the setup window at that step (a developer knob for UI review and smoke tests).
func runApp() -> Never {
    signal(SIGPIPE, SIG_IGN)            // a dead engine must not kill the UI through its pipe
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)     // the bundle has LSUIElement; this also holds for a bare binary
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let supervisor = EngineSupervisor()
    private(set) lazy var indicator = IndicatorPanel(supervisor: supervisor)
    private var statusMenu: StatusMenu?
    private lazy var setup = SetupWindow(supervisor: supervisor, app: self)
    private lazy var settings = SettingsWindow(app: self)

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        _ = indicator
        statusMenu = StatusMenu(app: self)
        if let step = ProcessInfo.processInfo.environment["MINEPOINTER_SETUP_STEP"].flatMap(Int.init) {
            showSetup(step: step)
        } else if UserDefaults.standard.bool(forKey: setupCompleteKey), CBManager.authorization == .allowedAlways, AXIsProcessTrusted() {
            supervisor.start()
        } else {
            showSetup()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app again (Finder, Spotlight, Launchpad) while it runs: a menu bar app has no window to bring back, and its
    /// icon may sit behind the notch, so show Settings (or the setup while it is not done).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { UserDefaults.standard.bool(forKey: setupCompleteKey) ? showSettings() : showSetup() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard supervisor.hasProcess else { return .terminateNow }
        supervisor.stop { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    // MARK: actions shared by the menu and the windows

    func showSetup(step: Int? = nil) { setup.show(step: step) }
    func showSettings() { settings.show() }

    func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// Writes the `indicator` key and shows or hides the panel at once (the engine ignores the key).
    func setIndicator(_ on: Bool) {
        do { try updateConfigFile(["indicator": on]) } catch { supervisor.note("could not write config.json: \(error.localizedDescription)") }
        indicator.setEnabled(on)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { try LaunchAtLogin.set(on) } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = on ? "Couldn’t turn on Launch at Login" : "Couldn’t turn off Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: main menu (invisible for an accessory app, but it makes ⌘C, ⌘V, ⌘W, ⌘Q and ⌘, work in the windows)

    private func installMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(), menu = NSMenu(title: title)
            build(menu)
            item.submenu = menu
            main.addItem(item)
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            menu.addItem(item)
        }
        submenu("MinePointer") { menu in
            add(menu, "About MinePointer", #selector(showAboutAction), "", target: self)
            menu.addItem(.separator())
            add(menu, "Settings…", #selector(showSettingsAction), ",", target: self)
            menu.addItem(.separator())
            add(menu, "Hide MinePointer", #selector(NSApplication.hide(_:)), "h")
            menu.addItem(.separator())
            add(menu, "Quit MinePointer", #selector(NSApplication.terminate(_:)), "q")
        }
        submenu("Edit") { menu in
            add(menu, "Undo", Selector(("undo:")), "z")
            add(menu, "Redo", Selector(("redo:")), "z", [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Cut", #selector(NSText.cut(_:)), "x")
            add(menu, "Copy", #selector(NSText.copy(_:)), "c")
            add(menu, "Paste", #selector(NSText.paste(_:)), "v")
            add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
        }
        submenu("Window") { menu in
            add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(menu, "Close", #selector(NSWindow.performClose(_:)), "w")
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.last?.submenu
    }

    @objc private func showAboutAction() { showAbout() }
    @objc private func showSettingsAction() { showSettings() }
}
