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
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model.engine)
                .environmentObject(model.store)
        } label: {
            MenuBarIcon(firstLaunch: model.firstLaunch)
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
        engine = MountEngine(store: store, log: log)
        engine.start()
        if firstLaunch { LoginItem.set(true) }
        // `AutoShareMount --reconnect` (from Terminal, Shortcuts or a script) acts like a wake.
        DistributedNotificationCenter.default().addObserver(forName: CLI.reconnectNote, object: nil, queue: .main) { [engine] _ in
            Task { @MainActor in engine.reconnectAll() }
        }
    }
}

enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AutoShareMount: login item change failed: \(error)")
        }
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
