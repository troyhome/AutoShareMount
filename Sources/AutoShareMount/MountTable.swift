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

/// Keeps drives at their usual path (/Volumes/<share>).
///
/// When a connection dies uncleanly, macOS can leave an empty folder behind in /Volumes.
/// The next connection then lands at "/Volumes/<share>-1", which breaks apps that remember
/// paths. Removing the folder needs admin rights, but it belongs to the user, so we can
/// mount straight onto it instead.
enum MountPoint {
    /// "/Volumes/2 Set 6TB-1" for share "2 Set 6TB".
    static func isRenamed(_ path: String, share: String) -> Bool {
        let ns = path as NSString
        let last = ns.lastPathComponent
        guard ns.deletingLastPathComponent == "/Volumes", last.hasPrefix(share + "-") else { return false }
        return Int(last.dropFirst(share.count + 1)) != nil
    }

    static func usualPath(for share: String) -> String { "/Volumes/" + share }

    /// An empty folder owned by this user at /Volumes/<share> that isn't a mounted volume.
    static func reusableLeftover(for share: String) -> URL? {
        let path = usualPath(for: share)
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return nil }
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let mountedOn = withUnsafeBytes(of: fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard mountedOn != path else { return nil }   // it's a real volume
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path),
              items.allSatisfy({ [".DS_Store", ".localized"].contains($0) }) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The usual path is free (nothing there) or only an empty leftover is in the way.
    static func usualPathAvailable(for share: String) -> Bool {
        !FileManager.default.fileExists(atPath: usualPath(for: share)) || reusableLeftover(for: share) != nil
    }
}
