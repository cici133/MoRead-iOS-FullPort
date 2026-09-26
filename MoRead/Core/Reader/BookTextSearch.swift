import Foundation

struct BookSearchHit: Identifiable, Hashable, Sendable {
    let id: String
    let chapterIndex: Int
    let chapterTitle: String
    let startUTF16: Int
    let endUTF16: Int
    let excerpt: String
    let anchorText: String
    let anchorRelativeOffset: Int
}

enum BookTextSearch {
    static func search(bookId: Int64, chapters: [Chapter], query rawQuery: String, limit: Int = 300) async throws -> [BookSearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let qLength = (query as NSString).length
        guard qLength > 0 else { return [] }
        var results: [BookSearchHit] = []
        for chapter in chapters.sorted(by: { $0.chapterIndex < $1.chapterIndex }) {
            try Task.checkCancellation()
            let body = try await LibraryRepository.shared.chapterText(chapter)
            let ns = body as NSString
            var cursor = 0
            while cursor < ns.length, results.count < limit {
                let remaining = NSRange(location: cursor, length: ns.length - cursor)
                let hit = ns.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
                if hit.location == NSNotFound { break }
                let radius = 54
                let excerptStart = max(0, hit.location - radius)
                let excerptEnd = min(ns.length, NSMaxRange(hit) + radius)
                let excerpt = ns.substring(with: NSRange(location: excerptStart, length: excerptEnd - excerptStart))
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let anchorStart = max(0, hit.location - 24)
                let anchorEnd = min(ns.length, NSMaxRange(hit) + 36)
                let anchor = ns.substring(with: NSRange(location: anchorStart, length: anchorEnd - anchorStart))
                results.append(.init(
                    id: "\(chapter.chapterIndex):\(hit.location):\(results.count)",
                    chapterIndex: chapter.chapterIndex,
                    chapterTitle: chapter.title,
                    startUTF16: hit.location,
                    endUTF16: NSMaxRange(hit),
                    excerpt: excerpt,
                    anchorText: anchor,
                    anchorRelativeOffset: hit.location - anchorStart
                ))
                cursor = hit.location + max(1, hit.length)
            }
            if results.count >= limit { break }
        }
        return results
    }

    static func anchor(around offset: Int, in text: String, before: Int = 24, after: Int = 36) -> (text: String, relative: Int) {
        let ns = text as NSString
        let safe = min(max(0, offset), ns.length)
        let start = max(0, safe - before)
        let end = min(ns.length, safe + after)
        guard end > start else { return ("", 0) }
        return (ns.substring(with: NSRange(location: start, length: end - start)), safe - start)
    }
}
