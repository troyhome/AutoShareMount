import AppKit
import SwiftUI

extension ShareStatus {
    var color: Color {
        switch self {
        case .mounted: return .green
        case .connecting, .waiting: return .orange
        case .needsSignIn, .failed: return .red
        case .ejected, .off: return .secondary
        }
    }
}

struct StatusDot: View {
    let status: ShareStatus?
    var body: some View {
        Circle()
            .fill((status ?? .connecting).color)
            .frame(width: 9, height: 9)
    }
}

extension FoundComputer.Kind {
    var symbol: String {
        switch self {
        case .mac: return "laptopcomputer"
        case .pc: return "pc"
        case .server: return "server.rack"
        }
    }
}

/// Menu bar icon: plain when all is well, with a badge when something needs attention.
struct MenuBarIcon: View {
    @EnvironmentObject var engine: MountEngine
    @Environment(\.openWindow) private var openWindow
    let firstLaunch: Bool

    var body: some View {
        let problem = engine.status.values.contains { $0.needsAttention }
        Image(systemName: problem ? "externaldrive.badge.exclamationmark" : "externaldrive.connected.to.line.below")
            .onAppear {
                // First launch: show the window so people see what was found.
                if firstLaunch {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { OpenMainWindow(openWindow: openWindow)() }
                }
            }
    }
}

func revealInFinder(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}
