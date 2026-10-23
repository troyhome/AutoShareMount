import Foundation

/// A network volume currently mounted on this Mac.
struct MountedVolume: Hashable {
    let scheme: String
    let user: String?
    let host: String
    let name: String
    let path: String

    /// True for Macs signed in with the same Apple ID ("com.apple.idms.appleid…" users).
    var isAppleIDLogin: Bool { user?.hasPrefix("com.apple.idms") == true }

    /// The address to reconnect with. Apple ID logins are stored without a user name so macOS
    /// picks the Apple ID again instead of asking for a password.
    var shareURLString: String {
        ShareURL.make(scheme: scheme, user: isAppleIDLogin ? nil : user, host: host, share: name)
    }

    func matches(_ s: ShareURL) -> Bool {
        scheme == s.scheme && name.caseInsensitiveCompare(s.name) == .orderedSame && HostName.matches(host, s.host)
    }
}

enum MountTable {
    static func current() -> [MountedVolume] {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return [] }
        var out: [MountedVolume] = []
        for i in 0..<Int(n) {
            let fs = buf[i]
            let scheme: String
            switch cString(fs.f_fstypename) {
            case "smbfs": scheme = "smb"
            case "afpfs": scheme = "afp"
            default: continue
            }
            // f_mntfromname looks like //user@HOST/Share%20Name
            var from = cString(fs.f_mntfromname)
            if from.hasPrefix("//") { from.removeFirst(2) }
            guard let slash = from.firstIndex(of: "/") else { continue }
            let authority = from[..<slash]
            let rest = from[from.index(after: slash)...]
            var user: String?
            var host = String(authority)
            if let at = authority.lastIndex(of: "@") {
                user = String(authority[..<at]).removingPercentEncoding
                host = String(authority[authority.index(after: at)...])
            }
            host = host.removingPercentEncoding ?? host
            let rawName = String(rest.split(separator: "/").first ?? "")
            out.append(MountedVolume(scheme: scheme, user: user, host: host,
                                     name: rawName.removingPercentEncoding ?? rawName,
                                     path: cString(fs.f_mntonname)))
        }
        return out
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
}
