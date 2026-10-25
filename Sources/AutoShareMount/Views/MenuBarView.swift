import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var engine: MountEngine
    @EnvironmentObject var store: ShareStore
    @Environment(\.openWindow) private var openWindow

    private var connected: Int { store.shares.filter { $0.enabled && engine.status[$0.id]?.isMounted == true }.count }
    private var enabled: Int { store.shares.filter(\.enabled).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AutoShareMount").font(.headline)
                Spacer()
                if !store.shares.isEmpty {
                    Text(connected == enabled ? "All connected" : "\(connected) of \(enabled) connected")
                        .font(.subheadline)
                        .foregroundStyle(connected == enabled ? .green : .orange)
                }
            }

            if store.shares.isEmpty {
                Text("No drives yet. Find the computers on your network and pick the drives to keep connected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(store.shares) { s in
                        MenuShareRow(share: s, status: engine.status[s.id])
                    }
                }
            }

            if !engine.unsaved.isEmpty {
                Divider()
                Text("Also connected").font(.caption).foregroundStyle(.secondary)
                ForEach(engine.unsaved, id: \.self) { m in
                    HStack {
                        Image(systemName: "externaldrive").foregroundStyle(.secondary)
                        Text(m.name).lineLimit(1)
                        Spacer()
                        Button("Keep connected") { engine.keep(m) }
                            .controlSize(.small)
                    }
                }
            }

            Divider()
            HStack {
                Button("Reconnect All") { engine.reconnectAll() }
                    .disabled(store.shares.isEmpty)
                Spacer()
                Button(store.shares.isEmpty ? "Find Drives…" : "Open…") { OpenMainWindow(openWindow: openWindow)() }
                    .keyboardShortcut(.defaultAction)
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit AutoShareMount")
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct MenuShareRow: View {
    @EnvironmentObject var engine: MountEngine
    let share: SavedShare
    let status: ShareStatus?
    @State private var hover = false

    var body: some View {
        Button {
            if case .mounted(let path)? = status { revealInFinder(path) }
            else if case .needsSignIn? = status { engine.signIn(share.id) }
            else { engine.reconnect(share.id) }
        } label: {
            HStack(spacing: 8) {
                StatusDot(status: status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(share.title).lineLimit(1)
                    Text(status?.isMounted == true ? share.server : "\(share.server) · \(status?.label ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(status?.isMounted == true ? "Open in Finder" : "Reconnect now")
    }
}
