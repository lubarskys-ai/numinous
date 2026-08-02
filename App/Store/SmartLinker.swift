import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device LLM layer (Apple Foundation Models) that reads a captured note and
/// pulls out the specific people, places, venues, and things the writer names —
/// each with a clean corrected title and a **folder path**, chosen to reuse the
/// folders you already have (so a golf course lands in your "golf clubs", a town in
/// "location"). `AppModel` turns those into link suggestions.
///
/// Available only on iOS 26+ Apple-Intelligence devices; everywhere else this is a
/// no-op and the deterministic `AutoLinker` stands alone.
enum SmartLinker {
    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Generable
    struct Entity {
        @Guide(description: "The exact words for this thing as they literally appear in the note, copied verbatim.")
        let surface: String
        @Guide(description: "A clean, properly capitalized and correctly spelled name or title.")
        let name: String
        @Guide(description: "A lowercase folder path to file this under (e.g. people, location, golf clubs, entertainment/restaurant). Reuse one of the user's existing folders when it fits.")
        let folder: String
    }

    @available(iOS 26.0, *)
    @Generable
    struct Extraction {
        @Guide(description: "Every specific person, place, venue, business, book, or film the writer names. Skip generic activity words like dinner, golf, run, work, or friend.")
        let entities: [Entity]
    }

    @available(iOS 26.0, *)
    static func extract(from text: String, folders: [String]) async -> [Entity] {
        guard isAvailable else { return [] }
        let existing = folders.isEmpty ? "people, location, entertainment/restaurant" : folders.joined(separator: ", ")
        let instructions = """
        You read a short personal note and list the specific people, places, venues, \
        businesses, books, and films the writer names, filing each under a lowercase \
        folder path. Rules:
        - A city, town, neighborhood, or region is 'location' (Carmel-by-the-Sea → location), \
        even if a meal or activity happened there.
        - A specific restaurant, cafe, or bar is 'entertainment/restaurant'.
        - A person is 'people'.
        - Reuse one of the user's existing folders whenever it fits: \(existing).
        - Skip generic activity words (dinner, golf, run, work) — only name real entities.
        For each entity copy the exact words, give a clean corrected name, and choose the folder.
        """
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: text, generating: Extraction.self)
            return response.content.entities
        } catch {
            return []
        }
    }

    /// Normalize an LLM-suggested folder path (lowercase, trimmed), reusing an
    /// existing folder when it matches and falling back to "notes" when empty.
    static func cleanFolder(_ raw: String, existing: [String]) -> String {
        let f = raw.lowercased()
            .replacingOccurrences(of: " / ", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !f.isEmpty else { return "notes" }
        return existing.first { $0.lowercased() == f } ?? f
    }

    @available(iOS 26.0, *)
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// nil when the on-device model is ready; otherwise a human-readable reason,
    /// so the capture UI can explain why new-entity suggestions didn't appear.
    @available(iOS 26.0, *)
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible):
            return "This iPhone can't run Apple's on-device model."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to auto-detect people & places."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading — try again shortly."
        case .unavailable(let other):
            return "On-device model unavailable (\(other))."
        @unknown default:
            return "On-device model unavailable."
        }
    }
    #endif
}
