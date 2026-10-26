import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case drives = "My Drives"
    case find = "Find Drives"
    case help = "How to Share"
    case activity = "Activity"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .drives: return "externaldrive.connected.to.line.below"
        case .find: return "magnifyingglass"
        case .help: return "questionmark.circle"
        case .activity: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var store: ShareStore
    // ASM_SECTION=find opens straight to a page (used for testing).
    @State private var section: Section? = Section.allCases.first {
        $0.rawValue.lowercased().hasPrefix(ProcessInfo.processInfo.environment["ASM_SECTION"]?.lowercased() ?? "~")
    } ?? .drives

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch section ?? .drives {
            case .drives: DrivesView(section: $section)
            case .find: FindView()
            case .help: HelpView(section: $section)
            case .activity: ActivityView()
            case .settings: SettingsView()
            }
        }
        .onAppear { if store.shares.isEmpty { section = .find } }
    }
}

// MARK: - My Drives

struct DrivesView: View {
    @EnvironmentObject var engine: MountEngine
    @EnvironmentObject var store: ShareStore
    @Binding var section: Section?
    @State private var showAdd = false

    var body: some View {
        Group {
            if store.shares.isEmpty && engine.unsaved.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "externaldrive.badge.plus").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("No drives yet").font(.title2)
                    Text("AutoShareMount can look for Macs and PCs on your network.")
                        .foregroundStyle(.secondary)
                    Button("Find Drives on My Network") { section = .find }
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if engine.vpnMayBeBlocking {
                        VPNHint().listRowSeparator(.hidden)
                    }
                    if !store.shares.isEmpty {
                        SwiftUI.Section {
                            ForEach(store.shares) { s in DriveRow(share: s) }
                        } header: {
                            Text("Kept connected — reconnected automatically after sleep, restart or network changes")
                        }
                    }
                    if !engine.unsaved.isEmpty {
                        SwiftUI.Section("Connected now, but not kept connected") {
                            ForEach(engine.unsaved, id: \.self) { m in
                                HStack {
                                    Image(systemName: "externaldrive").foregroundStyle(.secondary).frame(width: 22)
                                    VStack(alignment: .leading) {
                                        Text(m.name)
                                        Text(HostName.display(m.host)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Keep Connected") { engine.keep(m) }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .navigationTitle("My Drives")
        .toolbar {
            ToolbarItemGroup {
                Button { engine.reconnectAll() } label: { Label("Reconnect All", systemImage: "arrow.clockwise") }
                    .help("Reconnect every drive now")
                Button { showAdd = true } label: { Label("Add", systemImage: "plus") }
                    .help("Connect to a computer by name or address")
            }
        }
        .sheet(isPresented: $showAdd) { ConnectByAddressSheet() }
    }
}

private struct DriveRow: View {
    @EnvironmentObject var engine: MountEngine
    let share: SavedShare

    var body: some View {
        let st = engine.status[share.id]
        HStack(spacing: 10) {
            StatusDot(status: st).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(share.title).font(.body.weight(.medium))
                Text("\(share.server) · \(st?.label ?? "Checking…")")
                    .font(.caption)
                    .foregroundStyle(st?.needsAttention == true ? .red : .secondary)
            }
            Spacer()
            if case .needsSignIn? = st {
                Button("Sign In…") { engine.signIn(share.id) }
            } else if case .mounted(let path)? = st {
                Button("Open") { revealInFinder(path) }
            } else {
                Button("Connect") { engine.reconnect(share.id) }
                    .disabled(st == .connecting)
            }
            Toggle("", isOn: Binding(get: { share.enabled }, set: { engine.setEnabled(share.id, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Reconnect automatically")
            Menu {
                Button("Reconnect Now") { engine.reconnect(share.id) }
                Button("Sign In Again…") { engine.signIn(share.id) }
                Divider()
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(share.url, forType: .string)
                }
                Button("Remove from List", role: .destructive) { engine.remove(share.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }
}

struct ConnectByAddressSheet: View {
    @EnvironmentObject var engine: MountEngine
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to a computer").font(.headline)
            Text("Type the computer's name or address. Finder will ask you to sign in and pick its drives — they're added here automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("e.g. CRUSHER, Office-Mac.local or 192.168.1.20", text: $address)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func connect() {
        var a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        for prefix in ["smb://", "afp://", "\\\\", "//"] where a.lowercased().hasPrefix(prefix) { a.removeFirst(prefix.count) }
        a = a.replacingOccurrences(of: "\\", with: "/")
        let host = String(a.split(separator: "/").first ?? Substring(a))
        engine.connect(toServer: host)
        dismiss()
    }
}

// MARK: - Find Drives

struct FindView: View {
    @EnvironmentObject var discovery: Discovery
    @EnvironmentObject var engine: MountEngine
    @EnvironmentObject var store: ShareStore
    @State private var showAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Computers and drives on your network").font(.title3.weight(.semibold))
                    Text("Click **Connect** next to a computer. macOS asks you to sign in (tick “Remember this password”) and choose its drives. AutoShareMount then keeps them connected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                if discovery.scanning { ProgressView().controlSize(.small).padding(.top, 4) }
            }
            .padding(16)

            Divider()

            if discovery.computers.isEmpty {
                VStack(spacing: 10) {
                    if discovery.scanning {
                        Text("Looking around your network…").foregroundStyle(.secondary)
                    } else {
                        Text("Nothing found yet.").font(.headline)
                        Text("Make sure file sharing is turned on for the other computer — see How to Share.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    group("Macs", discovery.computers.filter { $0.online && $0.kind == .mac })
                    group("Windows PCs", discovery.computers.filter { $0.online && $0.kind == .pc })
                    group("Other file servers", discovery.computers.filter { $0.online && $0.kind == .server })
                    group("Not on the network right now", discovery.computers.filter { !$0.online })
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .navigationTitle("Find Drives")
        .toolbar {
            ToolbarItemGroup {
                Button { showAdd = true } label: { Label("Connect by Address", systemImage: "keyboard") }
                    .help("Can't see it? Type its name or address")
                Button { Task { await discovery.scan(store: store) } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                    .disabled(discovery.scanning)
            }
        }
        .sheet(isPresented: $showAdd) { ConnectByAddressSheet() }
        .task { if discovery.lastScan == nil { await discovery.scan(store: store) } }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [FoundComputer]) -> some View {
        if !items.isEmpty {
            SwiftUI.Section(title) {
                ForEach(items) { c in ComputerRow(computer: c) }
            }
        }
    }
}

private struct ComputerRow: View {
    @EnvironmentObject var engine: MountEngine
    @EnvironmentObject var store: ShareStore
    let computer: FoundComputer

    private var unkept: [MountedVolume] {
        computer.connectedDrives.filter { !store.contains($0.shareURLString) }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: computer.kind.symbol)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(computer.online ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(computer.name).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if let ip = computer.ip, !ip.isEmpty, ip != computer.name { chip(ip, .secondary) }
                    if !computer.connectedDrives.isEmpty { chip("\(computer.connectedDrives.count) connected", .green) }
                    if computer.savedDriveCount > 0 { chip("\(computer.savedDriveCount) kept connected", .blue) }
                    if computer.hasSavedPassword { chip("password saved", .secondary) }
                }
            }
            Spacer()
            if !unkept.isEmpty {
                Button("Keep \(unkept.count) Connected") { unkept.forEach(engine.keep) }
            }
            Button(computer.connectedDrives.isEmpty ? "Connect…" : "Add Drives…") {
                engine.connect(toServer: computer.connectHost)
            }
            .disabled(!computer.online)
        }
        .padding(.vertical, 4)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }
}

// MARK: - Activity

struct ActivityView: View {
    @EnvironmentObject var log: ActivityLog

    var body: some View {
        List(log.entries) { e in
            HStack(alignment: .firstTextBaseline) {
                Text(e.date, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Text(e.text).textSelection(.enabled)
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            Button { NSWorkspace.shared.activateFileViewerSelecting([ActivityLog.fileURL]) } label: {
                Label("Show Log File", systemImage: "doc.text.magnifyingglass")
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @State private var loginOn = LoginItem.wanted

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle("Open AutoShareMount when I log in", isOn: $loginOn)
                    .onChange(of: loginOn) { LoginItem.wanted = $0 }
                Text("Needed so drives reconnect after a restart. It also reopens AutoShareMount if it ever quits unexpectedly. Turning it off may close AutoShareMount; open it from Applications to use it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Local Network access") {
                Text("AutoShareMount checks whether your computers are reachable before connecting, which keeps reconnecting fast. If macOS asked to let it find devices on your local network, it should be allowed.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Local Network Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                }
            }
            SwiftUI.Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                LabeledContent("Saved drives", value: ShareStore.folder.path)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
