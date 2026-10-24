import AppKit
import ServiceManagement
import SwiftUI

@main
enum Main {
    static func main() {
        if CLI.handle(Array(CommandLine.arguments.dropFirst())) { return }
        AutoShareMountApp.main()
    }
}

struct AutoShareMountApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model.engine)
                .environmentObject(model.store)
        } label: {
            MenuBarIcon()
                .environmentObject(model.engine)
        }
        .menuBarExtraStyle(.window)

        Window("AutoShareMount", id: "main") {
            MainWindow()
                .environmentObject(model.engine)
                .environmentObject(model.store)
                .environmentObject(model.discovery)
                .environmentObject(model.log)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 820, height: 560)
    }
}

@MainActor
final class AppModel: ObservableObject {
    let store = ShareStore()
    let log = ActivityLog()
    let discovery = Discovery()
    let engine: MountEngine
    let firstLaunch: Bool

    init() {
        firstLaunch = store.isFirstLaunch
        ShareStoreFlags.firstLaunch = firstLaunch
        engine = MountEngine(store: store, log: log)
        engine.start()
        LoginItem.applyPreference()
        // `AutoShareMount --reconnect` (from Terminal, Shortcuts or a script) acts like a wake.
        DistributedNotificationCenter.default().addObserver(forName: CLI.reconnectNote, object: nil, queue: .main) { [engine] _ in
            Task { @MainActor in engine.reconnectAll() }
        }
    }
}

enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// What the user chose in Settings (on unless they turned it off).
    static var wanted: Bool {
        get { UserDefaults.standard.object(forKey: "openAtLogin") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "openAtLogin"); set(newValue) }
    }

    /// Re-registers on every launch: a moved or re-signed app can lose its login item.
    static func applyPreference() {
        if wanted != isOn { set(wanted) }
    }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AutoShareMount: login item change failed: \(error)")
        }
    }
}

/// The menu bar icon can be hidden (a full menu bar on a MacBook with a notch hides icons),
/// so opening the app from Finder / Launchpad / Spotlight must show the window too.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Self.launchedAtLogin() || ShareStoreFlags.firstLaunch {
            WindowOpener.request()
        }
    }

    /// Opening the app again while it's running (double-click, Spotlight, `open`).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowOpener.request()
        return true
    }

    /// True when macOS started us as a login item rather than the user opening the app.
    private static func launchedAtLogin() -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        // Login items started by launchd don't always carry that flag: treat a launch within
        // the first minutes after boot as a login launch.
        return ProcessInfo.processInfo.systemUptime < 180
    }
}

enum ShareStoreFlags {
    static var firstLaunch = false
}

/// Opens the main window from places that have no SwiftUI environment (the app delegate).
/// The action is captured from the menu bar icon's view as soon as it exists.
@MainActor
enum WindowOpener {
    static var action: OpenWindowAction? { didSet { if pending { request() } } }
    private static var pending = false

    static func request() {
        guard let action else { pending = true; return }
        pending = false
        DispatchQueue.main.async { OpenMainWindow(openWindow: action)() }
    }
}

/// Brings up the main window (the app has no Dock icon, so it must activate itself).
struct OpenMainWindow {
    let openWindow: OpenWindowAction
    func callAsFunction() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
