import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a raw, spoken diary transcript into clean first-person prose — entirely on the
/// device, using Apple Intelligence's system language model (iOS 26+). Nothing is sent to
/// any server. When the model isn't available (older device, model still downloading, etc.)
/// `polish` returns nil and the caller keeps the raw text, so dictation still works.
enum DiaryPolisher {
    enum Status {
        case available
        case unavailable(String)   // a short reason to show the user
    }

    /// Whether on-device polishing can run right now.
    static var status: Status {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(.deviceNotEligible):
                return .unavailable("This device doesn't support on-device polishing.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable("Turn on Apple Intelligence in Settings to polish entries.")
            case .unavailable(.modelNotReady):
                return .unavailable("The on-device model is still downloading. Try again soon.")
            case .unavailable:
                return .unavailable("On-device polishing isn't available right now.")
            @unknown default:
                return .unavailable("On-device polishing isn't available right now.")
            }
        }
        #endif
        return .unavailable("On-device polishing needs iOS 26 with Apple Intelligence.")
    }

    static var isAvailable: Bool {
        if case .available = status { return true }
        return false
    }

    /// Rewrite `raw` into a tidy diary entry, preserving every name and inventing nothing.
    /// Returns nil if the model is unavailable or errors — caller falls back to `raw`.
    static func polish(_ raw: String) async -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = status {
            do {
                let session = LanguageModelSession {
                    """
                    You clean up a spoken, dictated diary entry into clear first-person prose.
                    Rules:
                    - Keep it in the first person, past tense.
                    - Preserve EVERY name of a person, place, book, restaurant, or thing exactly \
                    as spoken — these become links, so do not drop or rephrase them.
                    - Do not invent events, feelings, or details that were not said.
                    - Remove filler words and false starts; fix punctuation and paragraphing.
                    - Keep it concise and faithful. Output ONLY the cleaned diary entry.
                    """
                }
                let response = try await session.respond { trimmed }
                let out = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return out.isEmpty ? nil : out
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}
