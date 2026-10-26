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

    var body: some View {
        let problem = engine.status.values.contains { $0.needsAttention }
        Image(systemName: problem ? "externaldrive.badge.exclamationmark" : "externaldrive.connected.to.line.below")
            .onAppear { WindowOpener.action = openWindow }
    }
}

func revealInFinder(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

/// Shown when a VPN is on and a drive can't connect: VPNs often hide the home network.
struct VPNHint: View {
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
                .font(compact ? .body : .title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("A VPN is on and may be blocking your home network")
                    .font((compact ? Font.callout : Font.body).weight(.semibold))
                Text("Open your VPN's settings and turn on **Allow LAN connections** (sometimes called “Local network access”), or disconnect the VPN while you're at home.")
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}
