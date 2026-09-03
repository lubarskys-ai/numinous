import Foundation
import NuminousCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Summarises a raw, spoken or rambling diary entry into a clear, faithful first-person
/// account — entirely on the device, using Apple Intelligence's system language model
/// (iOS 26+). Nothing is sent to any server. Every outcome is explicit (a summary, or a
/// human-readable reason it couldn't) so the UI never silently falls back.
enum DiaryPolisher {
    enum Outcome {
        case summary(String)     // a cleaned, condensed entry
        case skipped(String)     // a short reason to show the user
    }

    /// Whether on-device summarising can run right now (mirrors SmartLinker's checks).
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Condense `raw` into a tidy first-person diary entry, preserving every name and
    /// inventing nothing. Always returns — either a summary or the reason it couldn't.
    static func summarize(_ raw: String) async -> Outcome {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return .skipped("There isn't enough written yet to summarize.") }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: break
            case .unavailable(.deviceNotEligible):
                return .skipped("This iPhone can't run Apple's on-device model.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return .skipped("Turn on Apple Intelligence in Settings to summarize entries.")
            case .unavailable(.modelNotReady):
                return .skipped("Apple Intelligence is still downloading — try again shortly.")
            case .unavailable:
                return .skipped("On-device summarizing isn't available right now.")
            @unknown default:
                return .skipped("On-device summarizing isn't available right now.")
            }

            let instructions = """
            You help keep a personal diary. You are given one raw diary entry — often \
            dictated, rambling, or repetitive. Write a clear, faithful FIRST-PERSON \
            summary of it: what happened, who was there, where, and how I felt.
            Rules:
            - First person, past tense. Warm and plain, like my own diary voice.
            - CONDENSE: capture what mattered in a few tight sentences or short \
            paragraphs — cut filler, repetition, and false starts. This is a summary, \
            not a transcript.
            - Preserve EVERY specific name of a person, place, book, restaurant, film, \
            or thing exactly as I said it — these become links.
            - Invent nothing. Do not add events, feelings, or details I did not say.
            - PLAIN TEXT ONLY. No Markdown: no *asterisks*, no **bold**, no underscores, \
            no backticks, no bullet characters, no # headings. Just sentences.
            - Output ONLY the summarized entry, no preamble or headings.
            """
            let result = await withTimeout(seconds: 40) { () -> String? in
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: trimmed)
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Belt and braces: the model still slips in **bold** now and then, and a note is
            // plain text, so the markers would just sit there in the entry.
            if let s = result.map(PlainText.stripMarkdown), !s.isEmpty { return .summary(s) }
            return .skipped("On-device summarizing didn't finish in time — kept your entry as is.")
        }
        #endif
        return .skipped("On-device summarizing needs iOS 26 with Apple Intelligence.")
    }

    /// Run `op`, returning nil if it throws or doesn't finish within `seconds` — so a
    /// hung/cold on-device model can never leave the caller spinning forever.
    private static func withTimeout(seconds: Double, _ op: @escaping () async throws -> String?) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
