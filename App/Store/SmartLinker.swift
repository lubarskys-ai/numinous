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
        @Guide(description: "A lowercase folder for this entity: people, location, books, or notes. Use notes when you are unsure. Only use entertainment/restaurant for an actual named place to eat or drink.")
        let folder: String
    }

    @available(iOS 26.0, *)
    @Generable
    struct Extraction {
        @Guide(description: "Only the specific, clearly-named people, places, businesses, books, and films the writer actually names. Be conservative: skip generic words (dinner, golf, work, friend) and skip anything you're unsure is a real named entity.")
        let entities: [Entity]
    }

    @available(iOS 26.0, *)
    static func extract(from text: String, folders: [String]) async -> [Entity] {
        guard isAvailable else { return [] }
        let existing = folders.isEmpty ? "people, location, books" : folders.joined(separator: ", ")
        let instructions = """
        You read a short personal note and list only the specific, clearly-named \
        people, places, businesses, books, and films the writer actually mentions, \
        filing each under a lowercase folder. Be conservative — when in doubt, leave \
        it out. Choosing the folder:
        - A person → people
        - A city, town, neighborhood, or region → location (even if a meal or activity \
        happened there)
        - A book → books; a film or show → entertainment/film
        - A named restaurant, cafe, or bar → entertainment/restaurant, but ONLY when it \
        is genuinely a place to eat or drink. Do NOT put other things there.
        - Anything else, or whenever you are unsure what kind of thing it is → notes
        You may reuse one of the user's existing folders only when it clearly fits: \(existing).
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
