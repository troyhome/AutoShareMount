import AppKit
import ServiceManagement
import SwiftUI

@main
enum Main {
    static func main() {
        if CLI.handle(Array(CommandLine.arguments.dropFirst())) { return }
        guard SingleInstance.claim() else { return }
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

/// Starts the app at login through the launch agent bundled in Contents/Library/LaunchAgents,
/// which also reopens it if it ever quits unexpectedly.
enum LoginItem {
    static var agentLabel: String { (Bundle.main.bundleIdentifier ?? "io.github.autosharemount") + ".agent" }
    static var agent: SMAppService { SMAppService.agent(plistName: agentLabel + ".plist") }
    static var isOn: Bool { agent.status == .enabled }

    /// True when launchd started this copy as the agent (login, or a restart after a crash).
    static var launchedByAgent: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == agentLabel }

    /// What the user chose in Settings (on unless they turned it off).
    static var wanted: Bool {
        get { UserDefaults.standard.object(forKey: "openAtLogin") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "openAtLogin"); set(newValue) }
    }

    /// Runs on every launch: a moved, updated or re-signed app can lose its registration.
    static func applyPreference() {
        // 1.0.0–1.0.3 used a plain login item; the agent replaces it.
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        // Register even if macOS says it's enabled: that also reloads the agent if it was
        // unloaded behind our back. Registering again is harmless.
        if wanted || isOn { set(wanted) }
        // Opened by hand (e.g. after quitting): start the agent copy, which is the one
        // macOS restarts after a crash. This copy hands over to it a moment later.
        if wanted, !launchedByAgent {
            Net.run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(agentLabel)"], timeout: 5)
        }
    }

    static func set(_ on: Bool) {
        do {
            if on { try agent.register() } else { try agent.unregister() }
        } catch {
            NSLog("AutoShareMount: login item change failed: \(error)")
        }
    }
}

/// Only one copy runs. The copy launchd manages (the agent) wins, because it's the one that
/// gets restarted after a crash; a copy opened by hand hands over and quits.
enum SingleInstance {
    static let showWindowNote = Notification.Name("io.github.autosharemount.show-window")
    static let handOverNote = Notification.Name("io.github.autosharemount.hand-over")

    /// Called before the app starts. Returns false if this copy should exit right away.
    static func claim() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }   // dev build
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != getpid() }
        guard !others.isEmpty else { return true }
        let dnc = DistributedNotificationCenter.default()
        if LoginItem.launchedByAgent {
            dnc.postNotificationName(handOverNote, object: nil, userInfo: nil, deliverImmediately: true)
            return true
        }
        dnc.postNotificationName(showWindowNote, object: nil, userInfo: nil, deliverImmediately: true)
        return false
    }

    @MainActor
    static func listen() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: showWindowNote, object: nil, queue: .main) { _ in
            Task { @MainActor in WindowOpener.request() }
        }
        guard !LoginItem.launchedByAgent else { return }
        dnc.addObserver(forName: handOverNote, object: nil, queue: .main) { _ in
            Task { @MainActor in handOver() }
        }
        // The agent may start a moment after us (we just registered it), possibly before we
        // were listening: look again shortly.
        for delay in [2.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if otherCopyRunning() { handOver() }
            }
        }
    }

    private static func otherCopyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != getpid() }
    }

    /// Pass our window (if showing) to the agent copy, then quit.
    @MainActor
    private static func handOver() {
        let windowOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if windowOpen {
            DistributedNotificationCenter.default().postNotificationName(showWindowNote, object: nil, userInfo: nil, deliverImmediately: true)
        }
        NSApp.terminate(nil)
    }
}

/// The menu bar icon can be hidden (a full menu bar on a MacBook with a notch hides icons),
/// so opening the app from Finder / Launchpad / Spotlight must show the window too.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SingleInstance.listen()
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
        if LoginItem.launchedByAgent { return true }   // login, or restarted after a crash
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
