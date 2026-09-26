import Foundation

enum ReaderAnchorResolver {
    /// Resolves a DOM/WebKit UTF-16 offset back into the canonical text.mz coordinate system.
    /// EPUB markup can introduce whitespace and image nodes, so the visible text itself is the
    /// stable anchor; approximate offset is used only to choose among repeated occurrences.
    static func resolve(needle: String, approximateOffset: Int, in canonical: String) -> Int? {
        let query = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return min(max(0, approximateOffset), canonical.utf16.count) }
        let haystack = canonical as NSString
        let utf16Query = query as NSString
        var search = NSRange(location: 0, length: haystack.length)
        var best: (location: Int, distance: Int)?
        while search.length > 0 {
            let hit = haystack.range(of: utf16Query as String, options: [], range: search)
            if hit.location == NSNotFound { break }
            let distance = abs(hit.location - approximateOffset)
            if best == nil || distance < best!.distance { best = (hit.location, distance) }
            let next = hit.location + max(1, hit.length)
            if next >= haystack.length { break }
            search = NSRange(location: next, length: haystack.length - next)
        }
        return best?.location
    }

    static func resolveSelection(_ selection: ReaderSelection, in canonical: String) -> NSRange? {
        let total = (canonical as NSString).length
        if let start = selection.canonicalStart, let end = selection.canonicalEnd, start >= 0, end > start, end <= total {
            return NSRange(location: start, length: end - start)
        }
        guard let start = resolve(needle: selection.text, approximateOffset: selection.approximateUTF16Offset, in: canonical) else { return nil }
        let length = (selection.text as NSString).length
        guard length > 0, start + length <= total else { return nil }
        return NSRange(location: start, length: length)
    }

    static func excerpt(around offset: Int, in text: String, radius: Int = 36) -> String {
        let ns = text as NSString
        guard ns.length > 0 else { return "" }
        let start = max(0, min(ns.length, offset) - radius)
        let end = min(ns.length, max(0, offset) + radius)
        return ns.substring(with: NSRange(location: start, length: max(0, end - start))).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
