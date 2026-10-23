import Foundation

/// A network share address such as `smb://troy@CRUSHER/Movies%20Shows`.
struct ShareURL: Hashable {
    let url: URL
    let scheme: String      // "smb" or "afp"
    let host: String        // decoded: "CRUSHER", "Mac-Mini.local", "Troy’s Mac._smb._tcp.local"
    let user: String?
    let name: String        // decoded share name
    let port: UInt16

    init?(_ string: String) {
        guard let u = URL(string: string),
              let scheme = u.scheme?.lowercased(), ["smb", "afp", "cifs"].contains(scheme),
              let host = u.host(percentEncoded: false), !host.isEmpty else { return nil }
        let first = u.path(percentEncoded: false).split(separator: "/").first.map(String.init)
        guard let first, !first.isEmpty else { return nil }
        url = u
        self.scheme = scheme == "cifs" ? "smb" : scheme
        self.host = host
        user = u.user(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 }
        name = first
        port = UInt16(u.port ?? (self.scheme == "afp" ? 548 : 445))
    }

    /// Builds a URL string from decoded parts, percent-encoding as needed.
    static func make(scheme: String, user: String?, host: String, share: String?) -> String {
        let h = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
        let u = user.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) }.map { "\($0)@" } ?? ""
        let s = share.map { "/" + ($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0) } ?? ""
        return "\(scheme)://\(u)\(h)\(s)"
    }

    /// Identity used to tell whether two addresses mean the same share.
    var key: String { "\(scheme)|\(HostName.normalize(host))|\(name.lowercased())" }

    var serverDisplayName: String { HostName.display(host) }
}

enum HostName {
    static let bonjourSuffixes = ["._smb._tcp.local", "._afpovertcp._tcp.local"]

    static func isBonjourService(_ h: String) -> Bool {
        let l = h.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return bonjourSuffixes.contains { l.hasSuffix($0) }
    }

    /// "Troy’s Code MacBook Air._smb._tcp.local" → "Troy’s Code MacBook Air", "Mini.local" → "Mini".
    static func display(_ h: String) -> String {
        var s = h.removingPercentEncoding ?? h
        if s.hasSuffix(".") { s.removeLast() }
        for suffix in bonjourSuffixes + [".local"] where s.lowercased().hasSuffix(suffix) {
            s.removeLast(suffix.count)
            break
        }
        return s
    }

    /// A Mac shows up under two names: its Bonjour name ("Troy’s Code MacBook Air") and its
    /// hostname ("Troys-Code-MacBook-Air.local"). Both reduce to "troyscodemacbookair".
    static func normalize(_ h: String) -> String {
        let s = display(h).lowercased()
        if Net.isIPLiteral(s) { return s }
        return String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func matches(_ a: String, _ b: String) -> Bool {
        if normalize(a) == normalize(b) { return true }
        if let ia = Net.cachedIP(a), let ib = Net.cachedIP(b) { return ia == ib }
        return false
    }
}
