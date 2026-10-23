import Foundation

/// Command-line options, handy for troubleshooting:
///   AutoShareMount --status      saved drives and whether they're connected/reachable
///   AutoShareMount --scan        what Find Drives sees on the network
///   AutoShareMount --reconnect   tell the running app to reconnect everything now
enum CLI {
    static let reconnectNote = Notification.Name("io.github.autosharemount.reconnect")

    static func handle(_ args: [String]) -> Bool {
        guard let cmd = args.first(where: { $0.hasPrefix("--") }) else { return false }
        switch cmd {
        case "--reconnect":
            DistributedNotificationCenter.default().postNotificationName(reconnectNote, object: nil, userInfo: nil, deliverImmediately: true)
            print("Asked AutoShareMount to reconnect.")
        case "--status":
            runAsync { await status() }
        case "--scan":
            runAsync { await scan() }
        case "--help", "-h":
            print("usage: AutoShareMount [--status | --scan | --reconnect]")
        default:
            return false   // e.g. -NSDocumentRevisionsDebugMode from Xcode
        }
        return true
    }

    private static func runAsync(_ work: @escaping @MainActor () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in await work(); done.signal() }
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    @MainActor private static func status() async {
        let store = ShareStore()
        let mounts = MountTable.current()
        if store.shares.isEmpty { print("No saved drives.") }
        for s in store.shares {
            guard let p = s.parsed else { continue }
            let t0 = Date()
            let r = await Net.reachable(p)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let m = mounts.first { $0.matches(p) }
            print("\(m != nil ? "●" : "○") \(p.name) on \(p.serverDisplayName) — \(m.map { "connected at \($0.path)" } ?? "not connected"), \(r == .no ? "unreachable" : "reachable") (\(ms) ms)\(s.enabled ? "" : " [auto-reconnect off]")")
        }
        let other = mounts.filter { m in !store.shares.contains { $0.parsed.map(m.matches) ?? false } }
        for m in other { print("  also connected: \(m.name) on \(HostName.display(m.host)) (not kept connected)") }
    }

    @MainActor private static func scan() async {
        let d = Discovery()
        let t0 = Date()
        await d.scan(store: ShareStore())
        print("Scan took \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        for c in d.computers {
            var tags: [String] = [c.kind.rawValue]
            if let ip = c.ip, !ip.isEmpty { tags.append(ip) }
            if !c.online { tags.append("offline") }
            if c.hasSavedPassword { tags.append("password saved") }
            if !c.connectedDrives.isEmpty { tags.append("connected: " + c.connectedDrives.map(\.name).joined(separator: ", ")) }
            print("• \(c.name)  [\(tags.joined(separator: " · "))]  → smb://\(c.connectHost)")
        }
    }
}
