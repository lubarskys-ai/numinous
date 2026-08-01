import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device LLM layer (Apple Foundation Models) that augments the deterministic
/// `AutoLinker`: it reads a captured note and names the specific people, books,
/// activities, and places the writer refers to — resolving pronouns and indirect
/// phrasing ("the guy from the gym", "that book my sister recommended") that exact
/// string-matching can't. We then match those names back to notes you already have.
///
/// Available only on iOS 26+ Apple-Intelligence devices; everywhere else this is a
/// no-op and the deterministic matcher stands alone.
enum SmartLinker {
    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Generable
    struct Mentions {
        @Guide(description: "The specific people, books, activities, places, and things the writer refers to — concrete proper names or titles, never generic words like 'friend' or 'book'.")
        let names: [String]
    }

    @available(iOS 26.0, *)
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @available(iOS 26.0, *)
    static func mentions(in text: String) async -> [String] {
        guard isAvailable else { return [] }
        let session = LanguageModelSession(instructions:
            "You extract the specific people, books, activities, places, and things a writer mentions in a short personal note. Resolve pronouns and indirect references to the actual name or title when the note makes it clear. Return only concrete names and titles, not generic words.")
        do {
            let response = try await session.respond(to: text, generating: Mentions.self)
            return response.content.names
        } catch {
            return []
        }
    }
    #endif
}
