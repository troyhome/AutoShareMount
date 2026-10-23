import Foundation
import Network

/// Name resolution and fast reachability checks.
enum Net {
    enum Reach { case yes, no, maybeBlocked }

    // MARK: IP cache (normalized host → IP)

    private static let lock = NSLock()
    private static var ipCache: [String: String] = [:]

    static func isIPLiteral(_ h: String) -> Bool {
        var a = in_addr(), a6 = in6_addr()
        return inet_pton(AF_INET, h, &a) == 1 || inet_pton(AF_INET6, h, &a6) == 1
    }

    static func cachedIP(_ host: String) -> String? {
        if isIPLiteral(host) { return host }
        lock.lock(); defer { lock.unlock() }
        return ipCache[HostName.normalize(host)]
    }

    static func remember(_ host: String, ip: String) {
        lock.lock(); ipCache[HostName.normalize(host)] = ip; lock.unlock()
    }

    // MARK: Reachability

    /// Cached IP first (a few ms), re-resolve only if that fails.
    static func reachable(_ s: ShareURL) async -> Reach {
        if let ip = cachedIP(s.host), tcpProbe(ip, s.port).ok { return .yes }
        if HostName.isBonjourService(s.host) {
            if let ip = await bonjourProbe(serviceHost: s.host) { remember(s.host, ip: ip); return .yes }
            return .no
        }
        guard let ip = await resolve(s.host) else { return .no }
        let r = tcpProbe(ip, s.port)
        if r.ok { return .yes }
        // "No route to host" for an address that just resolved is what macOS returns when
        // Local Network access hasn't been granted. Let the mount itself (done by a system
        // service that isn't blocked) decide.
        return r.err == EHOSTUNREACH ? .maybeBlocked : .no
    }

    static func resolve(_ host: String) async -> String? {
        if isIPLiteral(host) { return host }
        let h = host
        let ip: String? = await Task.detached {
            if let ip = withTimeout(2.5, { getaddrinfoIP(h) }) { return ip }
            if !h.contains(".") {
                if let ip = netbiosIP(h) { return ip }
                if let ip = withTimeout(2.5, { getaddrinfoIP(h + ".local") }) { return ip }
            }
            return nil
        }.value
        if let ip { remember(host, ip: ip) }
        return ip
    }

    /// Non-blocking TCP connect with a short timeout.
    static func tcpProbe(_ ip: String, _ port: UInt16, timeoutMs: Int32 = 900) -> (ok: Bool, err: Int32) {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, String(port), &hints, &res) == 0, let ai = res else { return (false, EINVAL) }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return (false, errno) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 { return (true, 0) }
        guard errno == EINPROGRESS else { return (false, errno) }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) == 1 else { return (false, ETIMEDOUT) }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return (err == 0, err)
    }

    /// Connects to a Bonjour service ("Name._smb._tcp.local") and returns its IP if it answers.
    static func bonjourProbe(serviceHost: String, timeout: TimeInterval = 2.5) async -> String? {
        let parts = splitBonjour(serviceHost)
        let ep = NWEndpoint.service(name: parts.name, type: parts.type, domain: "local.", interface: nil)
        return await connectProbe(ep, timeout: timeout)
    }

    static func splitBonjour(_ host: String) -> (name: String, type: String) {
        let l = host.lowercased()
        for (suffix, type) in [("._smb._tcp.local", "_smb._tcp"), ("._afpovertcp._tcp.local", "_afpovertcp._tcp")] {
            let trimmed = l.hasSuffix(".") ? String(host.dropLast()) : host
            if trimmed.lowercased().hasSuffix(suffix) { return (String(trimmed.dropLast(suffix.count)), type) }
        }
        return (host, "_smb._tcp")
    }

    /// Opens a TCP connection with Network.framework; returns the remote IP once ready.
    static func connectProbe(_ ep: NWEndpoint, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let conn = NWConnection(to: ep, using: .tcp)
            let q = DispatchQueue(label: "probe")
            var finished = false
            func finish(_ v: String?) {
                guard !finished else { return }
                finished = true
                conn.cancel()
                cont.resume(returning: v)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var ip: String?
                    if case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint {
                        switch host {
                        case .ipv4(let a): ip = "\(a)"
                        case .ipv6(let a): ip = "\(a)".components(separatedBy: "%").first
                        case .name(let n, _): ip = n
                        @unknown default: break
                        }
                    }
                    finish(ip ?? "")
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    // MARK: Lookups

    static func getaddrinfoIP(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let res else { return nil }
        defer { freeaddrinfo(res) }
        var best: String?
        var p: UnsafeMutablePointer<addrinfo>? = res
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buf)
                if ai.pointee.ai_family == AF_INET { return ip }   // prefer IPv4
                if best == nil, !ip.hasPrefix("fe80") { best = ip }
            }
            p = ai.pointee.ai_next
        }
        return best
    }

    /// Reverse lookup (mDNS answers for Macs: "Troys-Mac.local").
    static func reverseName(_ ip: String) -> String? {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &sa.sin_addr) == 1 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD)
            }
        }
        return rc == 0 ? String(cString: buf) : nil
    }

    /// NetBIOS name → IP for Windows names like "CRUSHER" that DNS doesn't know.
    static func netbiosIP(_ host: String) -> String? {
        let out = run("/usr/bin/smbutil", ["lookup", host], timeout: 2)
        for line in out.split(separator: "\n") where line.contains("IP address of") {
            if let ip = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces), isIPLiteral(ip) { return ip }
        }
        return nil
    }

    /// IP → NetBIOS server name (answers for Windows PCs and most NAS boxes).
    static func netbiosName(_ ip: String) -> String? {
        let out = run("/usr/bin/smbutil", ["status", ip], timeout: 2)
        for line in out.split(separator: "\n") where line.hasPrefix("Server:") {
            let name = line.dropFirst("Server:".count).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return nil
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let killer = DispatchWorkItem {
            guard p.isRunning else { return }
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Runs a blocking call on another thread; gives up waiting after `timeout`.
    static func withTimeout<T>(_ timeout: TimeInterval, _ work: @escaping () -> T?) -> T? {
        let sem = DispatchSemaphore(value: 0)
        let box = Box<T>()
        DispatchQueue.global().async {
            box.set(work())
            sem.signal()
        }
        guard sem.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.get()
    }

    private final class Box<T> {
        private let l = NSLock()
        private var v: T?
        func set(_ x: T?) { l.lock(); v = x; l.unlock() }
        func get() -> T? { l.lock(); defer { l.unlock() }; return v }
    }

    // MARK: Local interfaces

    struct LocalNet { let ip: String; let mask: String }

    /// Active IPv4 networks of this Mac (Wi‑Fi / Ethernet), for scanning.
    static func localIPv4Networks() -> [LocalNet] {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var out: [LocalNet] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            let flags = Int32(i.pointee.ifa_flags)
            guard let addr = i.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let maskPtr = i.pointee.ifa_netmask else { continue }
            let name = String(cString: i.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            func str(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
                return String(cString: buf)
            }
            out.append(LocalNet(ip: str(addr), mask: str(maskPtr)))
        }
        return out
    }

    /// All host addresses on a network, capped to the nearest /22 around our address.
    static func hosts(in net: LocalNet) -> [String] {
        var a = in_addr(), m = in_addr()
        guard inet_pton(AF_INET, net.ip, &a) == 1, inet_pton(AF_INET, net.mask, &m) == 1 else { return [] }
        let ip = UInt32(bigEndian: a.s_addr)
        var mask = UInt32(bigEndian: m.s_addr)
        if mask.nonzeroBitCount < 22 { mask = 0xFFFF_FC00 }
        let base = ip & mask
        let count = ~mask
        guard count > 1 else { return [] }
        return (1..<count).compactMap { off -> String? in
            let h = base + off
            if h == ip { return nil }
            return "\(h >> 24).\((h >> 16) & 0xFF).\((h >> 8) & 0xFF).\(h & 0xFF)"
        }
    }
}
