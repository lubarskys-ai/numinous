import Foundation

// MARK: - Wire types (Readwise export API v2)

/// One book / article / podcast / tweet returned by GET /api/v2/export/.
/// Kindle books arrive as `category == "books"` with an `asin`.
struct ReadwiseBook: Decodable, Sendable {
    let userBookId: Int
    let title: String?
    let author: String?
    let readableTitle: String?
    let category: String?          // books | articles | tweets | podcasts
    let source: String?
    let coverImageUrl: String?
    let summary: String?
    let asin: String?
    let bookTags: [ReadwiseTag]?
    let highlights: [ReadwiseHighlight]?
}

struct ReadwiseTag: Decodable, Sendable { let name: String? }

struct ReadwiseHighlight: Decodable, Sendable {
    let text: String?
    let note: String?
    let location: Int?
    let highlightedAt: String?
    let isFavorite: Bool?
    let tags: [ReadwiseTag]?
}

/// Decodes to nil instead of throwing, so one malformed record can't sink the
/// whole page — the array decode keeps going and we drop just the bad row.
private struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private struct ReadwiseExportPage: Decodable {
    let results: [Failable<ReadwiseBook>]
    let nextPageCursor: String?
    /// The rows that decoded cleanly.
    var books: [ReadwiseBook] { results.compactMap(\.value) }

    enum CodingKeys: String, CodingKey { case results, nextPageCursor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decodeIfPresent([Failable<ReadwiseBook>].self, forKey: .results) ?? []
        // Readwise returns the cursor as a string on some accounts and a number on
        // others — accept either (and null/absent), normalizing to a string.
        if let s = try? c.decode(String.self, forKey: .nextPageCursor) {
            nextPageCursor = s.isEmpty ? nil : s
        } else if let i = try? c.decode(Int.self, forKey: .nextPageCursor) {
            nextPageCursor = String(i)
        } else {
            nextPageCursor = nil
        }
    }
}

/// Reads your Kindle (and other) highlights from Readwise. Readwise is the bridge
/// Amazon doesn't give us: it syncs Kindle highlights and exposes them here, so a
/// book you actually read becomes a note (growing Mind) with its highlights inline
/// — and any `[[link]]` you put in a highlight carries straight into your web.
enum ReadwiseService {

    enum ReadwiseError: LocalizedError {
        case badToken, network(String)
        var errorDescription: String? {
            switch self {
            case .badToken: return "That Readwise token wasn't accepted. Check it and try again."
            case .network(let m): return m
            }
        }
    }

    /// Pull every book + its highlights, following cursor pagination. Filtered to
    /// `categories` (defaults to real books). Throws `.badToken` on 401.
    static func fetch(token: String, categories: Set<String> = ["books"]) async throws -> [ReadwiseBook] {
        var all: [ReadwiseBook] = []
        var cursor: String? = nil
        repeat {
            var comps = URLComponents(string: "https://readwise.io/api/v2/export/")!
            if let cursor { comps.queryItems = [URLQueryItem(name: "pageCursor", value: cursor)] }
            var request = URLRequest(url: comps.url!)
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ReadwiseError.network("No response from Readwise.") }
            if http.statusCode == 401 { throw ReadwiseError.badToken }
            guard (200..<300).contains(http.statusCode) else {
                throw ReadwiseError.network("Readwise returned status \(http.statusCode).")
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let page: ReadwiseExportPage
            do {
                page = try decoder.decode(ReadwiseExportPage.self, from: data)
            } catch {
                throw ReadwiseError.network("Couldn't read Readwise's response (\(describe(error))).")
            }
            // If rows came back but none matched our format, strict-decode to learn
            // exactly why, instead of silently importing nothing.
            if page.books.isEmpty, !page.results.isEmpty {
                throw ReadwiseError.network("Readwise sent \(page.results.count) item(s) in an unexpected format (\(firstRowError(in: data, decoder: decoder))).")
            }
            all.append(contentsOf: page.books)
            cursor = page.nextPageCursor
        } while cursor != nil

        return all.filter { categories.contains($0.category ?? "books") }
    }

    /// A human-readable reason for a decode failure — which field, what was wrong.
    private static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        func path(_ ctx: DecodingError.Context) -> String {
            let p = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return p.isEmpty ? "top level" : p
        }
        switch e {
        case .keyNotFound(let key, let ctx):   return "missing '\(key.stringValue)' at \(path(ctx))"
        case .typeMismatch(let type, let ctx): return "wrong type (expected \(type)) at \(path(ctx))"
        case .valueNotFound(let type, let ctx):return "unexpected null (\(type)) at \(path(ctx))"
        case .dataCorrupted(let ctx):          return "corrupted data at \(path(ctx))"
        @unknown default:                      return error.localizedDescription
        }
    }

    /// Strict-decode the page (no per-row rescue) to surface the first row's error.
    private static func firstRowError(in data: Data, decoder: JSONDecoder) -> String {
        struct StrictPage: Decodable { let results: [ReadwiseBook] }
        do { _ = try decoder.decode(StrictPage.self, from: data); return "unknown reason" }
        catch { return describe(error) }
    }

    // MARK: - Grading

    /// Base intensity by *type* of read — a book is a deeper commitment than a tweet.
    static func typeBase(_ category: String?) -> Int {
        switch category {
        case "books":    return 4
        case "podcasts": return 3
        case "articles": return 2
        case "tweets":   return 1
        default:         return 3
        }
    }

    /// Genre nudges, matched case-insensitively against the book's Readwise tags.
    /// Editable in one place — self-help trumps non-fiction trumps fiction, and
    /// romance takes a hit (per request). The most decisive genre (largest
    /// magnitude) wins when a book carries several.
    static let genreWeights: [String: Int] = [
        "self-help": 1, "selfhelp": 1, "self help": 1, "personal-development": 1,
        "personal development": 1, "psychology": 1, "philosophy": 1, "productivity": 1,
        "non-fiction": 0, "nonfiction": 0, "biography": 0, "memoir": 0,
        "history": 0, "science": 0, "business": 0,
        "fiction": -1, "novel": -1, "fantasy": -1, "sci-fi": -1, "scifi": -1,
        "romance": -2,
    ]

    static func genreAdjust(_ tags: [ReadwiseTag]?) -> Int {
        let hits = (tags ?? []).compactMap { tag -> Int? in
            guard let name = tag.name?.lowercased().trimmingCharacters(in: .whitespaces) else { return nil }
            return genreWeights[name]
        }
        // Most decisive genre wins (e.g. a "romance" -2 outweighs a stray "fiction").
        return hits.max(by: { abs($0) < abs($1) }) ?? 0
    }

    /// Combined grade: type base + engagement (a heavily-highlighted read links
    /// harder) + genre, clamped to the 1…5 the rest of the app uses.
    static func intensity(for book: ReadwiseBook) -> Int {
        let engagement = (book.highlights?.count ?? 0) >= 12 ? 1 : 0
        let raw = typeBase(book.category) + engagement + genreAdjust(book.bookTags)
        return min(5, max(1, raw))
    }

    /// Folder each type files into (all grow Mind, but keep their own default
    /// intensity so a shelf of tweets can't out-weigh a shelf of books).
    static func folder(_ category: String?) -> String {
        switch category {
        case "articles": return "articles"
        case "podcasts": return "podcasts"
        case "tweets":   return "tweets"
        default:         return "books"
        }
    }

    #if DEBUG
    /// Test-only stand-in for a real export, so the import flow is demoable in the
    /// simulator without a Readwise token. Chosen to show the genre gradient:
    /// self-help ⚡5 > non-fiction ⚡4 > fiction ⚡3 > romance ⚡2. One highlight
    /// carries a `[[people/Sam]]` link to show links flow through.
    static let sampleBooks: [ReadwiseBook] = [
        ReadwiseBook(
            userBookId: 90001, title: "Deep Work", author: "Cal Newport", readableTitle: nil,
            category: "books", source: "kindle",
            coverImageUrl: "https://images-na.ssl-images-amazon.com/images/P/B00X47ZVXM.jpg",
            summary: "On focus as a superpower in a distracted world.",
            asin: "B00X47ZVXM", bookTags: [ReadwiseTag(name: "self-help"), ReadwiseTag(name: "productivity")],
            highlights: sampleHighlights([
                "Clarity about what matters provides clarity about what does not.",
                "Human beings are at their best when immersed deeply in something challenging.",
                "Busyness is not a proxy for productivity.",
                "To produce at your peak you must work for long periods with full concentration.",
                "What you choose to focus on quietly defines the quality of your life.",
            ], count: 20, firstNote: "reminds me of [[people/Sam]]'s advice about single-tasking")),
        ReadwiseBook(
            userBookId: 90002, title: "Sapiens", author: "Yuval Noah Harari", readableTitle: nil,
            category: "books", source: "kindle",
            coverImageUrl: "https://images-na.ssl-images-amazon.com/images/P/B00ICN066A.jpg",
            summary: "A brief history of humankind.",
            asin: "B00ICN066A", bookTags: [ReadwiseTag(name: "non-fiction"), ReadwiseTag(name: "history")],
            highlights: sampleHighlights([
                "Fiction has enabled us not merely to imagine things, but to do so collectively.",
                "We did not domesticate wheat. It domesticated us.",
                "Money is the most universal system of mutual trust ever devised.",
                "Culture tends to argue that it forbids only that which is unnatural.",
            ], count: 8)),
        ReadwiseBook(
            userBookId: 90003, title: "The Midnight Library", author: "Matt Haig", readableTitle: nil,
            category: "books", source: "kindle",
            coverImageUrl: "https://images-na.ssl-images-amazon.com/images/P/B0851LXCH3.jpg",
            summary: "A novel about the lives we might have lived.",
            asin: "B0851LXCH3", bookTags: [ReadwiseTag(name: "fiction"), ReadwiseTag(name: "novel")],
            highlights: sampleHighlights([
                "The only way to learn is to live.",
                "Never underestimate the big importance of small things.",
                "Regret doesn't leave. But it can transform into something else.",
            ], count: 5)),
        ReadwiseBook(
            userBookId: 90004, title: "Beach Read", author: "Emily Henry", readableTitle: nil,
            category: "books", source: "kindle",
            coverImageUrl: "https://images-na.ssl-images-amazon.com/images/P/B07X7VZ7DF.jpg",
            summary: "Two writers, one summer, opposite genres.",
            asin: "B07X7VZ7DF", bookTags: [ReadwiseTag(name: "romance")],
            highlights: sampleHighlights([
                "Maybe happy endings weren't real, but people were.",
                "Sometimes what feels like the end is really the middle.",
                "Writing is just professional daydreaming.",
            ], count: 3)),
    ]

    /// Cycles a book's quotes into `count` highlights (keeps the highlight count —
    /// which drives the engagement grade — while the text stays varied).
    private static func sampleHighlights(_ quotes: [String], count: Int,
                                         firstNote: String? = nil) -> [ReadwiseHighlight] {
        (0..<count).map { i in
            ReadwiseHighlight(text: quotes[i % quotes.count],
                              note: i == 0 ? firstNote : nil,
                              location: i, highlightedAt: nil, isFavorite: i == 0, tags: nil)
        }
    }
    #endif
}
