import Foundation
import NuminousCore

/// Parses a folder of Markdown files — an Obsidian vault — into notes Numinous
/// can ingest. The mapping is almost 1:1, because Numinous already speaks
/// Obsidian's dialect: a `.md` file becomes one note, its vault subfolder becomes
/// the note's folder, its filename becomes the display name, and its `[[wikilinks]]`
/// resolve through the same `WikilinkParser` the rest of the app uses.
///
/// YAML frontmatter (the leading `--- … ---` block) is lifted out: a `date`/`created`
/// field sets the note's date, other flat scalar fields become details, and the
/// whole block is stripped from the body so it doesn't clutter the note.
enum ObsidianMarkdownImporter {

    struct ParsedNote {
        /// Vault subfolder path, e.g. "People" or "Work/Projects" ("" = vault root).
        var folder: String
        /// Filename without its extension.
        var name: String
        var body: String
        var date: Date?
        var details: [NoteDetail]
        /// Path relative to the vault root — a stable id for idempotent re-import.
        var relativePath: String
    }

    /// Recursively read every markdown file under `root`. Skips Obsidian's own
    /// config/trash folders and any non-markdown file.
    static func parse(vaultAt root: URL) -> [ParsedNote] {
        let fm = FileManager.default
        var results: [ParsedNote] = []
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            let lower = url.lastPathComponent.lowercased()
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                // Don't descend into Obsidian's own machinery.
                if lower == ".obsidian" || lower == ".trash" { enumerator.skipDescendants() }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" else { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let rel = relativePath(of: url, under: root)
            let folder = (rel as NSString).deletingLastPathComponent   // "" at the root
            let name = url.deletingPathExtension().lastPathComponent

            let (body, front) = splitFrontmatter(raw)
            var details: [NoteDetail] = []
            var date: Date?
            for (key, value) in front {
                if date == nil,
                   ["date", "created", "date created"].contains(key.lowercased()),
                   let parsed = parseDate(value) {
                    date = parsed
                    continue
                }
                // Keep short flat scalars as details; ignore long or structural values.
                if !value.isEmpty, value.count <= 120 {
                    details.append(NoteDetail(key: key, value: value))
                }
            }

            results.append(ParsedNote(
                folder: folder,
                name: name,
                body: body.trimmingCharacters(in: .whitespacesAndNewlines),
                date: date,
                details: details,
                relativePath: rel
            ))
        }
        return results
    }

    /// The path of `url` relative to `root`, using "/" separators.
    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootParts = root.standardizedFileURL.pathComponents
        let urlParts = url.standardizedFileURL.pathComponents
        guard urlParts.count > rootParts.count,
              Array(urlParts.prefix(rootParts.count)) == rootParts else {
            return url.lastPathComponent
        }
        return urlParts.suffix(urlParts.count - rootParts.count).joined(separator: "/")
    }

    /// Split a leading `---\n … \n---` YAML block into (body, [(key, value)]).
    /// Only flat `key: value` scalars are read; nested/list values are skipped.
    private static func splitFrontmatter(_ text: String) -> (body: String, front: [(String, String)]) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (text, []) }

        var front: [(String, String)] = []
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                let body = lines[(i + 1)...].joined(separator: "\n")
                return (body, front)
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !key.isEmpty { front.append((key, value)) }
            }
            i += 1
        }
        // No closing delimiter → it wasn't really frontmatter; keep the whole text.
        return (text, [])
    }

    private static let dateFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "MM/dd/yyyy"]
            .map { format in
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = format
                return f
            }
    }()

    private static func parseDate(_ string: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
