import AppKit
import SwiftUI
import StationCore
import Darwin

// AppKit owns presentation so login launches can stay windowless on macOS 14.
// SwiftUI still owns the contents of the Station and Settings windows.
@main
enum YeelightStationApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            do {
                guard let resources = Bundle.main.url(forResource: "YeelightStationMac_StationCore", withExtension: "bundle") else {
                    throw StationError.unavailable("The packaged resource bundle is missing.")
                }
                let presets = try StationPresets.load()
                print("Packaged resources: \(resources.path)")
                print("Loaded \(presets.scenes.count) scenes, \(presets.palettes.count) palettes, \(presets.layouts.count) layouts.")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = StationAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

struct StationLaunchPolicy {
    let diagnostic: Bool
    let opensWindow: Bool

    init(arguments: [String], launchEvent: NSAppleEventDescriptor?) {
        diagnostic = arguments.contains("--diagnose-network")
        let login = launchEvent?.eventClass == kCoreEventClass &&
            launchEvent?.eventID == kAEOpenApplication &&
            launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        opensWindow = !diagnostic && !login
    }

    // Minimized and hidden windows still belong in the Dock. Closing the last
    // utility window, rather than switching Spaces or hiding it, removes it.
    static func showsDock(hasOpenStation: Bool, hasOpenSettings: Bool) -> Bool {
        hasOpenStation || hasOpenSettings
    }
}

@MainActor
final class StationAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = StationModel()
    private var statusItem: StationStatusItem?
    private var stationWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var stationOpen = false
    private var settingsOpen = false
    private var started = false
    private var diagnostic = false
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !started else { return }
        started = true
        // currentAppleEvent is only valid during this synchronous callback.
        let launch = StationLaunchPolicy(arguments: CommandLine.arguments,
                                        launchEvent: NSAppleEventManager.shared().currentAppleEvent)
        diagnostic = launch.diagnostic
        guard !diagnostic else {
            Task {
                if await NetworkDiagnostic.runIfRequested() {
                    // Let the diagnostic task finish before ending its process.
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            }
            return
        }
        installMainMenu()
        statusItem = StationStatusItem(model: model, openStation: { [weak self] in self?.openStation() },
                                      openSettings: { [weak self] in self?.openSettings() })
        model.begin()
        if launch.opensWindow { openStation() }
    }

    @objc func openStation() {
        guard !diagnostic, !terminating else { return }
        if stationWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 810),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Yeelight Station for Mac"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentMinSize = NSSize(width: 980, height: 700)
            window.contentViewController = NSHostingController(rootView:
                StationView().environmentObject(model).preferredColorScheme(.dark)
                    .frame(minWidth: 980, minHeight: 700))
            prepare(window, identifier: "station")
            stationWindow = window
        }
        stationOpen = true
        present(stationWindow)
    }

    @objc func openSettings() {
        guard !diagnostic, !terminating else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 650),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Station Settings"
            window.contentViewController = NSHostingController(rootView:
                ScrollView { SettingsView().environmentObject(model).padding(24) }
                    .frame(width: 560, height: 650).preferredColorScheme(.dark))
            prepare(window, identifier: "station-settings")
            settingsWindow = window
        }
        settingsOpen = true
        present(settingsWindow)
    }

    private func prepare(_ window: NSWindow, identifier: String) {
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.center()
    }

    private func present(_ window: NSWindow?) {
        updateActivationPolicy()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func updateActivationPolicy() {
        let showDock = StationLaunchPolicy.showsDock(hasOpenStation: stationOpen, hasOpenSettings: settingsOpen)
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === stationWindow { stationOpen = false }
        if window === settingsWindow { settingsOpen = false }
        updateActivationPolicy()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openStation()
        return false // Presentation is handled here, including minimized windows.
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Diagnostic startup deliberately skips model.begin and creates no capture,
        // light sessions or controls. Its completed read-only probes need no model cleanup.
        if diagnostic { return .terminateNow }
        // Repeated Quit requests must not bypass asynchronous cleanup.
        guard !terminating else { return .terminateLater }
        terminating = true
        statusItem?.isTerminating = true
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    @objc private func discoverLights() { Task { await model.scan() } }
    @objc private func stopSync() { Task { await model.stopSync() } }

    private func installMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu; main.addItem(item)
            return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ selector: Selector, key: String = "", target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = target; menu.addItem(item)
        }
        let app = submenu("Yeelight Station")
        add(app, "About Yeelight Station", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Settings…", #selector(openSettings), key: ",", target: self)
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services; app.addItem(servicesItem); NSApp.servicesMenu = services
        app.addItem(.separator())
        add(app, "Hide Station", #selector(NSApplication.hide(_:)), key: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]; app.addItem(hideOthers)
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit Yeelight Station", #selector(NSApplication.terminate(_:)), key: "q")
        let file = submenu("File")
        add(file, "Open Station", #selector(openStation), key: "o", target: self)
        add(file, "Discover Lights", #selector(discoverLights), key: "D", target: self)
        add(file, "Stop Sync", #selector(stopSync), key: ".", target: self)
        file.addItem(.separator())
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), key: "w")
        let edit = submenu("Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                       ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                       ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            add(edit, title, Selector(selector), key: key)
        }
        let window = submenu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}
