import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device LLM layer (Apple Foundation Models) that reads a captured note and
/// pulls out the specific people, places, restaurants, and things the writer
/// names — each with a clean corrected title and a classification we map to a
/// folder. `AppModel` turns those into link suggestions: matched to a note you
/// already have, or offered as a brand-new note to create.
///
/// Available only on iOS 26+ Apple-Intelligence devices; everywhere else this is a
/// no-op and the deterministic `AutoLinker` stands alone.
enum SmartLinker {
    #if canImport(FoundationModels)
    /// What an extracted entity is, so we can file it under the right folder.
    @available(iOS 26.0, *)
    @Generable
    enum Kind {
        case person, place, restaurant, book, film, activity, organization, thing
    }

    @available(iOS 26.0, *)
    @Generable
    struct Entity {
        @Guide(description: "The exact words for this thing as they literally appear in the note, copied verbatim so they can be found in the text.")
        let surface: String
        @Guide(description: "A clean, properly capitalized and correctly spelled name or title.")
        let name: String
        let kind: Kind
    }

    @available(iOS 26.0, *)
    @Generable
    struct Extraction {
        @Guide(description: "Every specific person, place, restaurant, book, film, activity, or organization the writer names. Skip generic words like 'dinner', 'friend', or 'work'.")
        let entities: [Entity]
    }

    /// The folder path a kind of entity is filed under (lowercased; matched to your
    /// folders case-insensitively). New notes land here when there's no existing one.
    @available(iOS 26.0, *)
    static func folder(for kind: Kind) -> String {
        switch kind {
        case .person:       return "people"
        case .place:        return "location"
        case .restaurant:   return "entertainment/restaurant"
        case .film:         return "entertainment/film"
        case .book:         return "notes"
        case .activity:     return "notes"
        case .organization: return "notes"
        case .thing:        return "notes"
        }
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

    @available(iOS 26.0, *)
    static func extract(from text: String) async -> [Entity] {
        guard isAvailable else { return [] }
        let session = LanguageModelSession(instructions:
            "You read a short personal note and list the specific people, places, restaurants, books, films, activities, and organizations the writer names. For each, copy the exact words from the note, give a clean corrected name, and classify it. Skip generic words.")
        do {
            let response = try await session.respond(to: text, generating: Extraction.self)
            return response.content.entities
        } catch {
            return []
        }
    }
    #endif
}
