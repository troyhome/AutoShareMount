import AppKit
import Foundation
import NetFS
import Network

enum ShareStatus: Equatable {
    case mounted(path: String)
    case connecting
    case waiting(String)       // server not reachable right now
    case ejected               // user ejected it while the server was up
    case needsSignIn(String)
    case failed(String)
    case off

    var label: String {
        switch self {
        case .mounted: return "Connected"
        case .connecting: return "Connecting…"
        case .waiting(let why): return why
        case .ejected: return "Ejected — reconnects after sleep or restart"
        case .needsSignIn(let why): return why
        case .failed(let why): return why
        case .off: return "Auto-reconnect off"
        }
    }

    var isMounted: Bool { if case .mounted = self { return true }; return false }
    var needsAttention: Bool {
        switch self { case .needsSignIn, .failed: return true; default: return false }
    }
}

/// Keeps saved shares mounted: at launch, after wake, on network changes, and every 30 s.
@MainActor
final class MountEngine: ObservableObject {
    @Published private(set) var status: [UUID: ShareStatus] = [:]
    /// Network drives that are mounted but not in the saved list ("Keep this connected?").
    @Published private(set) var unsaved: [MountedVolume] = []

    let store: ShareStore
    let log: ActivityLog

    private var inFlight = Set<UUID>()
    private var seenMounted = Set<UUID>()
    private var generation = 0
    private var fallbackTried: [UUID: Int] = [:]
    private var burstUntil = Date.distantPast
    private var burstRunning = false
    private var pendingConnect: (host: String, until: Date)?
    private var pathMonitor: NWPathMonitor?
    private var lastPathKey = ""
    private var observers: [NSObjectProtocol] = []
    private var lastHelperRestart = Date.distantPast

    init(store: ShareStore, log: ActivityLog) {
        self.store = store
        self.log = log
    }

    // MARK: Lifecycle

    func start() {
        log.add("AutoShareMount started")
        if store.isFirstLaunch {
            // Smart setup: keep whatever network drives are connected right now.
            let found = MountTable.current()
            for m in found { store.add(m.shareURLString) }
            store.save()
            if !found.isEmpty { log.add("First launch: added \(found.count) connected drive(s)") }
        }

        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.trigger("wake") }
            })
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }

        // Network changes: Wi‑Fi rejoining after wake, Ethernet, VPN…
        let mon = NWPathMonitor()
        mon.pathUpdateHandler = { [weak self] path in
            let key = "\(path.status)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            Task { @MainActor in
                guard let self, key != self.lastPathKey else { return }
                self.lastPathKey = key
                if path.status == .satisfied { self.trigger("network change") }
            }
        }
        mon.start(queue: DispatchQueue(label: "path"))
        pathMonitor = mon

        // Safety net for servers that come online later (another Mac waking, a PC booting).
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.tick()
            }
        }

        trigger("launch")
    }

    /// A real event: retry quickly for a while until everything is back.
    func trigger(_ reason: String, force: Bool = false) {
        generation += 1
        let mounts = MountTable.current()
        var missing = 0
        for s in store.shares where s.enabled {
            guard let p = s.parsed else { continue }
            if mounts.contains(where: { $0.matches(p) }) { seenMounted.insert(s.id) }
            else { seenMounted.remove(s.id); missing += 1 }
        }
        refresh()
        guard missing > 0 || force else { return }
        log.add("\(reason.capitalized): \(missing) drive(s) to reconnect")
        burstUntil = Date().addingTimeInterval(90)
        tick()
        runBurst()
    }

    private func runBurst() {
        guard !burstRunning else { return }
        burstRunning = true
        Task {
            while Date() < burstUntil {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if tick() == 0 { break }
            }
            burstRunning = false
        }
    }

    // MARK: State

    /// Updates statuses from the mount table without starting any mounts.
    func refresh() {
        let mounts = MountTable.current()
        for s in store.shares {
            guard let p = s.parsed else { continue }
            if let m = mounts.first(where: { $0.matches(p) }) {
                status[s.id] = .mounted(path: m.path)
                seenMounted.insert(s.id)
            } else if !s.enabled {
                status[s.id] = .off
            } else if status[s.id]?.isMounted == true {
                status[s.id] = .ejected
            }
        }
        // Drives connected in Finder after the user clicked "Connect" are added automatically.
        if let pc = pendingConnect, Date() < pc.until {
            for m in mounts where HostName.matches(m.host, pc.host) && !store.contains(m.shareURLString) {
                if let s = store.add(m.shareURLString) {
                    log.add("Added \(m.name) on \(HostName.display(m.host)) — it will reconnect automatically")
                    status[s.id] = .mounted(path: m.path)
                    seenMounted.insert(s.id)
                }
            }
        }
        unsaved = mounts.filter { m in !store.shares.contains { s in s.parsed.map { m.matches($0) } ?? false } }
    }

    /// Returns how many enabled shares are still not mounted.
    @discardableResult
    func tick() -> Int {
        let mounts = MountTable.current()
        var missing = 0
        for s in store.shares where s.enabled {
            guard let p = s.parsed else { continue }
            if let m = mounts.first(where: { $0.matches(p) }) {
                status[s.id] = .mounted(path: m.path)
                seenMounted.insert(s.id)
                continue
            }
            missing += 1
            guard !inFlight.contains(s.id) else { continue }
            if seenMounted.contains(s.id) {
                checkEjected(s, p)
            } else {
                attempt(s, p, manual: false)
            }
        }
        refresh()
        return missing
    }

    /// A drive vanished without a wake/network event. If its server is still up, the user
    /// ejected it: leave it alone. If the server is gone, reconnect once it's back.
    private func checkEjected(_ s: SavedShare, _ p: ShareURL) {
        inFlight.insert(s.id)
        Task {
            let r = await Net.reachable(p)
            inFlight.remove(s.id)
            if r == .no {
                seenMounted.remove(s.id)
                status[s.id] = .waiting("Waiting for \(p.serverDisplayName)")
            } else {
                status[s.id] = .ejected
            }
        }
    }

    // MARK: Mounting

    private func attempt(_ s: SavedShare, _ p: ShareURL, manual: Bool) {
        inFlight.insert(s.id)
        let gen = generation
        if status[s.id] == nil || manual { status[s.id] = .connecting }
        Task {
            defer { inFlight.remove(s.id); refresh() }
            let reach = await Net.reachable(p)
            if reach == .no && !manual {
                if status[s.id] != .waiting("Waiting for \(p.serverDisplayName)") {
                    log.add("\(p.name): \(p.serverDisplayName) isn't reachable yet")
                }
                status[s.id] = .waiting("Waiting for \(p.serverDisplayName)")
                return
            }
            if reach == .maybeBlocked {
                log.add("\(p.name): reachability check blocked — is Local Network access allowed? Trying anyway")
            }
            status[s.id] = .connecting
            let t0 = Date()
            var (rc, path) = await Self.netfsMount(p, timeout: 20)
            if rc == ETIMEDOUT, reach == .yes {
                // The server answers but the mount doesn't: macOS's network sign-in helper
                // (NetAuthSysAgent) has most likely stalled, which blocks every connection —
                // Finder's too. Restart it (at most every 5 minutes) and try again.
                if Date().timeIntervalSince(lastHelperRestart) > 300 {
                    lastHelperRestart = Date()
                    log.add("macOS's network sign-in helper isn't responding — restarting it")
                    await Self.restartNetAuthHelper()
                }
                if Date().timeIntervalSince(lastHelperRestart) < 60 {
                    (rc, path) = await Self.netfsMount(p, timeout: 20)
                }
            }
            if rc == ETIMEDOUT, fallbackTried[s.id] != gen || manual {
                // Seen with Mac-to-Mac Apple ID logins: NetFS without UI can stall. Try the
                // same path Finder's "Connect to Server" uses.
                fallbackTried[s.id] = gen
                log.add("\(p.name): no answer, trying Finder-style connect")
                if await Self.finderStyleMount(p), let m = MountTable.current().first(where: { $0.matches(p) }) {
                    (rc, path) = (0, m.path)
                }
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            switch rc {
            case 0, EEXIST:
                let mp = path ?? MountTable.current().first(where: { $0.matches(p) })?.path ?? ""
                status[s.id] = .mounted(path: mp)
                seenMounted.insert(s.id)
                log.add("\(p.name) on \(p.serverDisplayName): connected in \(ms) ms")
            case let c where Self.isAuthError(c):
                status[s.id] = .needsSignIn("Needs your password — click Sign In")
                log.add("\(p.name): needs a saved password (\(c))")
            case ETIMEDOUT:
                status[s.id] = .failed("\(p.serverDisplayName) isn't answering")
                log.add("\(p.name): timed out")
            default:
                status[s.id] = .failed(Self.describe(rc))
                log.add("\(p.name): \(Self.describe(rc)) (\(rc))")
            }
        }
    }

    func reconnect(_ id: UUID) {
        guard let s = store.shares.first(where: { $0.id == id }), let p = s.parsed, !inFlight.contains(id) else { return }
        generation += 1
        seenMounted.remove(id)
        attempt(s, p, manual: true)
    }

    func reconnectAll() { trigger("manual", force: true) }

    /// Opens the share in Finder, which shows macOS's own login window with
    /// "Remember this password in my keychain".
    func signIn(_ id: UUID) {
        guard let s = store.shares.first(where: { $0.id == id }), let p = s.parsed else { return }
        pendingConnect = (p.host, Date().addingTimeInterval(600))
        NSWorkspace.shared.open(p.url)
    }

    /// "Connect…" on a found computer: Finder asks for the login and which drives to use;
    /// every drive picked there is added to the list automatically.
    func connect(toServer host: String, scheme: String = "smb") {
        pendingConnect = (host, Date().addingTimeInterval(600))
        log.add("Connecting to \(HostName.display(host))…")
        if let url = URL(string: ShareURL.make(scheme: scheme, user: nil, host: host, share: nil)) {
            NSWorkspace.shared.open(url)
        }
    }

    func keep(_ m: MountedVolume) {
        if let s = store.add(m.shareURLString) {
            status[s.id] = .mounted(path: m.path)
            seenMounted.insert(s.id)
            log.add("Keeping \(m.name) on \(HostName.display(m.host)) connected")
        }
        refresh()
    }

    func remove(_ id: UUID) {
        store.remove(id)
        status[id] = nil
        refresh()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        store.setEnabled(id, on)
        if on { reconnect(id) } else { refresh() }
    }

    // MARK: NetFS

    /// Mounts like Finder (Keychain credentials) but never shows UI; cancels after `timeout`.
    nonisolated static func netfsMount(_ p: ShareURL, timeout: TimeInterval) async -> (Int32, String?) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Int32, String?), Never>) in
            let lock = NSLock()
            var done = false
            var requestID: AsyncRequestID?
            func finish(_ rc: Int32, _ path: String?) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                cont.resume(returning: (rc, path))
            }
            let open = NSMutableDictionary()
            open["UIOption"] = "NoUI"            // kNAUIOptionKey = kNAUIOptionNoUI
            let mountOpts = NSMutableDictionary()
            let q = DispatchQueue.global(qos: .userInitiated)
            let rc = NetFSMountURLAsync(p.url as CFURL, nil, p.user as CFString?, nil,
                                        open as CFMutableDictionary, mountOpts as CFMutableDictionary,
                                        &requestID, q) { status, _, points in
                finish(status, (points as? [String])?.first)
            }
            if rc != 0 { finish(rc, nil); return }
            q.asyncAfter(deadline: .now() + timeout) {
                if let requestID { NetFSMountURLCancel(requestID) }
                finish(ETIMEDOUT, nil)
            }
        }
    }

    /// NetAuthSysAgent runs as the user; launchd starts a fresh one on the next request.
    nonisolated static func restartNetAuthHelper() async {
        await Task.detached {
            Net.run("/usr/bin/killall", ["NetAuthSysAgent"], timeout: 3)
            Thread.sleep(forTimeInterval: 1)
        }.value
    }

    /// AppleScript "mount volume" — the Connect to Server path, which handles Apple ID logins.
    nonisolated static func finderStyleMount(_ p: ShareURL) async -> Bool {
        await Task.detached {
            let script = "mount volume \"\(p.url.absoluteString.replacingOccurrences(of: "\"", with: "%22"))\""
            Net.run("/usr/bin/osascript", ["-e", script], timeout: 40)
            return MountTable.current().contains { $0.matches(p) }
        }.value
    }

    nonisolated static func isAuthError(_ c: Int32) -> Bool {
        [EAUTH, EACCES, EPERM, -128, -5998, -6600, -6602].contains(c)
    }

    nonisolated static func describe(_ status: Int32) -> String {
        switch status {
        case ENOENT, -6003: return "Drive not found on that computer"
        case ECONNREFUSED: return "File sharing is off on that computer"
        case EHOSTUNREACH, ENETUNREACH: return "Can't reach that computer"
        default: return "Couldn't connect (error \(status))"
        }
    }
}
