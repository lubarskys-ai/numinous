import Foundation
import NuminousCore

struct StoredData: Codable {
    var notes: [Note]
    var folders: [Folder]
    var axes: [Axis]
}

/// Local-first persistence. For this model iteration everything is one JSON file
/// (notes carry structured details, which a flat markdown frontmatter can't hold
/// cleanly). Markdown import/export via NuminousCore's parser/serializer can be
/// layered back on later.
struct Storage {
    private let fm = FileManager.default
    private var root: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Numinous", isDirectory: true)
    }
    private var file: URL { root.appendingPathComponent("store.json") }

    init() { try? fm.createDirectory(at: root, withIntermediateDirectories: true) }

    func load() -> StoredData? {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(StoredData.self, from: data) else { return nil }
        return decoded
    }

    func save(_ data: StoredData) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: file, options: .atomic)
    }
}
