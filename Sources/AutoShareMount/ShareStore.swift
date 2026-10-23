import Foundation

struct SavedShare: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: String
    var enabled = true
    var addedAt = Date()

    var parsed: ShareURL? { ShareURL(url) }
    var title: String { parsed?.name ?? url }
    var server: String { parsed?.serverDisplayName ?? "" }
}

/// The user's list of drives to keep connected, saved as JSON in Application Support.
@MainActor
final class ShareStore: ObservableObject {
    @Published private(set) var shares: [SavedShare] = []

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AutoShareMount", isDirectory: true)
    private let file = ShareStore.folder.appendingPathComponent("shares.json")

    var isFirstLaunch: Bool { !FileManager.default.fileExists(atPath: file.path) }

    init() {
        if let data = try? Data(contentsOf: file) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            do {
                shares = try dec.decode([SavedShare].self, from: data)
            } catch {
                // Never silently overwrite a list we couldn't read.
                let backup = file.deletingPathExtension().appendingPathExtension("unreadable.json")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: file, to: backup)
                NSLog("AutoShareMount: couldn't read shares.json (\(error)); copy kept at \(backup.path)")
            }
        }
    }

    func contains(_ url: String) -> Bool {
        guard let key = ShareURL(url)?.key else { return false }
        return shares.contains { $0.parsed?.key == key }
    }

    @discardableResult
    func add(_ url: String) -> SavedShare? {
        guard ShareURL(url) != nil, !contains(url) else { return nil }
        let s = SavedShare(url: url)
        shares.append(s)
        shares.sort { ($0.server.lowercased(), $0.title.lowercased()) < ($1.server.lowercased(), $1.title.lowercased()) }
        save()
        return s
    }

    func remove(_ id: UUID) {
        shares.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = shares.firstIndex(where: { $0.id == id }) else { return }
        shares[i].enabled = on
        save()
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(shares) { try? data.write(to: file, options: .atomic) }
    }
}

/// Recent activity, shown in the app and written to ~/Library/Logs/AutoShareMount.log.
@MainActor
final class ActivityLog: ObservableObject {
    struct Entry: Identifiable { let id = UUID(); let date: Date; let text: String }
    @Published private(set) var entries: [Entry] = []

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AutoShareMount.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    func add(_ text: String) {
        let e = Entry(date: Date(), text: text)
        entries.insert(e, at: 0)
        if entries.count > 300 { entries.removeLast(entries.count - 300) }
        let line = "\(formatter.string(from: e.date))  \(text)\n"
        if let h = try? FileHandle(forWritingTo: Self.fileURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: Self.fileURL)
        }
    }
}
