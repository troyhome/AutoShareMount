import Foundation
import Network
import Security

struct FoundComputer: Identifiable, Hashable {
    enum Kind: String { case mac, pc, server }

    var key: String                 // normalized name, or IP
    var name: String                // what we show
    var connectHost: String         // what goes into smb://…
    var ip: String?
    var kind: Kind
    var online = true
    var hasSavedPassword = false
    var connectedDrives: [MountedVolume] = []
    var savedDriveCount = 0

    var id: String { key }
}

/// Finds file servers on the local network with no input from the user:
///  • Bonjour (_smb._tcp) — Macs, most NAS boxes
///  • a quick port‑445 sweep of the local network + NetBIOS names — Windows PCs
///  • drives already connected, and servers with a password saved in Keychain
@MainActor
final class Discovery: ObservableObject {
    @Published private(set) var computers: [FoundComputer] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date?

    func scan(store: ShareStore) async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false; lastScan = Date() }

        let localNets = Net.localIPv4Networks()
        let myIPs = Set(localNets.map(\.ip))
        let ips = localNets.flatMap { Net.hosts(in: $0) }

        async let smbServices = Self.browse(type: "_smb._tcp", seconds: 2.5)
        async let deviceInfo = Self.browseModels(seconds: 2.5)
        async let openHosts = Self.sweep(ips, port: 445)
        let (services, models, open) = await (smbServices, deviceInfo, openHosts)

        var byKey: [String: FoundComputer] = [:]
        func upsert(_ c: FoundComputer) {
            if var existing = byKey[c.key] {
                if existing.ip == nil { existing.ip = c.ip }
                byKey[c.key] = existing
            } else {
                byKey[c.key] = c
            }
        }

        // Bonjour services: resolve each to an IP in parallel.
        let me = HostName.normalize(Host.current().localizedName ?? "")
        let resolved: [(String, String?)] = await withTaskGroup(of: (String, String?).self) { g in
            for name in services {
                g.addTask {
                    let ip = await Net.connectProbe(.service(name: name, type: "_smb._tcp", domain: "local.", interface: nil), timeout: 2)
                    return (name, ip)
                }
            }
            var out: [(String, String?)] = []
            for await r in g { out.append(r) }
            return out
        }
        for (name, ip) in resolved {
            let key = HostName.normalize(name)
            guard key != me else { continue }
            let model = models[name] ?? ""
            let kind: FoundComputer.Kind = model.isEmpty || model.contains("Mac") ? .mac : .server
            let host = name + "._smb._tcp.local"
            if let ip, !ip.isEmpty { Net.remember(host, ip: ip) }
            upsert(FoundComputer(key: key, name: name, connectHost: host, ip: ip, kind: kind))
        }

        // Port‑445 sweep: anything not already found by Bonjour is named via NetBIOS / reverse DNS.
        let knownIPs = Set(byKey.values.compactMap(\.ip))
        let unknown = open.filter { !myIPs.contains($0) && !knownIPs.contains($0) }
        let named: [(String, String?, String?)] = await withTaskGroup(of: (String, String?, String?).self) { g in
            for ip in unknown {
                g.addTask { await Task.detached { (ip, Net.netbiosName(ip), Net.reverseName(ip)) }.value }
            }
            var out: [(String, String?, String?)] = []
            for await r in g { out.append(r) }
            return out
        }
        for (ip, netbios, reverse) in named {
            if let netbios {
                Net.remember(netbios, ip: ip)
                upsert(FoundComputer(key: HostName.normalize(netbios), name: netbios, connectHost: netbios, ip: ip, kind: .pc))
            } else if let reverse, HostName.normalize(reverse) != me {
                let key = HostName.normalize(reverse)
                if byKey[key] == nil {
                    upsert(FoundComputer(key: key, name: HostName.display(reverse), connectHost: reverse, ip: ip, kind: .server))
                } else {
                    if byKey[key]?.ip == nil { byKey[key]?.ip = ip }
                }
            } else {
                upsert(FoundComputer(key: ip, name: "Device at \(ip)", connectHost: ip, ip: ip, kind: .server))
            }
        }

        // Already-connected drives (their servers are obviously there).
        for m in MountTable.current() {
            let key = HostName.normalize(m.host)
            if byKey[key] == nil, let ip = Net.cachedIP(m.host), let k = byKey.first(where: { $0.value.ip == ip })?.key {
                byKey[k]?.connectedDrives.append(m)
                continue
            }
            if byKey[key] == nil {
                upsert(FoundComputer(key: key, name: HostName.display(m.host), connectHost: m.host, ip: Net.cachedIP(m.host),
                                     kind: m.host.contains(".") ? .mac : .pc))
            }
            byKey[key]?.connectedDrives.append(m)
        }

        // Servers you've saved a password for (names only — passwords are never read).
        for server in Self.keychainSMBServers() {
            let key = HostName.normalize(server)
            if byKey[key] != nil {
                byKey[key]?.hasSavedPassword = true
            } else if let ip = Net.cachedIP(server), let k = byKey.first(where: { $0.value.ip == ip })?.key {
                byKey[k]?.hasSavedPassword = true
            } else if !Net.isIPLiteral(server) {
                var c = FoundComputer(key: key, name: HostName.display(server), connectHost: server, ip: nil,
                                      kind: server.contains(".") ? .mac : .pc)
                c.online = false
                c.hasSavedPassword = true
                upsert(c)
            }
        }

        for (k, c) in byKey {
            byKey[k]?.savedDriveCount = store.shares.filter { s in s.parsed.map { HostName.matches($0.host, c.connectHost) } ?? false }.count
        }

        computers = byKey.values.sorted {
            ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased())
        }
    }

    // MARK: Bonjour

    nonisolated static func browse(type: String, seconds: Double) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: .tcp)
            let q = DispatchQueue(label: "browse")
            var names = Set<String>()
            browser.browseResultsChangedHandler = { results, _ in
                for r in results { if case let .service(name, _, _, _) = r.endpoint { names.insert(name) } }
            }
            browser.start(queue: q)
            q.asyncAfter(deadline: .now() + seconds) {
                browser.cancel()
                cont.resume(returning: Array(names))
            }
        }
    }

    /// Device models from `_device-info._tcp` ("MacBookAir10,1", "Xserve", NAS models…).
    nonisolated static func browseModels(seconds: Double) async -> [String: String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: String], Never>) in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_device-info._tcp", domain: "local."), using: .tcp)
            let q = DispatchQueue(label: "browse-model")
            var models: [String: String] = [:]
            browser.browseResultsChangedHandler = { results, _ in
                for r in results {
                    guard case let .service(name, _, _, _) = r.endpoint,
                          case let .bonjour(txt) = r.metadata, let model = txt["model"] else { continue }
                    models[name] = model
                }
            }
            browser.start(queue: q)
            q.asyncAfter(deadline: .now() + seconds) {
                browser.cancel()
                cont.resume(returning: models)
            }
        }
    }

    // MARK: Sweep

    /// Tries a TCP connection to `port` on every address, many at a time (~2–4 s for a /24).
    nonisolated static func sweep(_ ips: [String], port: UInt16) async -> [String] {
        await Task.detached { sweepBlocking(ips, port: port) }.value
    }

    nonisolated private static func sweepBlocking(_ ips: [String], port: UInt16) -> [String] {
            let lock = NSLock()
            var found: [String] = []
            let group = DispatchGroup()
            let gate = DispatchSemaphore(value: 64)
            for ip in ips {
                gate.wait()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    if Net.tcpProbe(ip, port, timeoutMs: 500).ok {
                        lock.lock(); found.append(ip); lock.unlock()
                    }
                    gate.signal()
                    group.leave()
                }
            }
            group.wait()
            return found
    }

    // MARK: Keychain

    nonisolated static func keychainSMBServers() -> [String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return Array(Set(items.compactMap { $0[kSecAttrServer as String] as? String }))
    }
}
