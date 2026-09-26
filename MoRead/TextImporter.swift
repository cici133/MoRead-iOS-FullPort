import CoreFoundation
import Foundation

struct TextImporter {
    static func loadSource(url: URL) throws -> TxtImportSource {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let text = decode(data) ?? normalize(String(decoding: data, as: UTF8.self))
        return .init(title: url.deletingPathExtension().lastPathComponent, text: text)
    }

    static func importTXT(url: URL, customPattern: String? = nil) throws -> ImportedBook {
        let source = try loadSource(url: url)
        return importedBook(source: source, sourceURL: url, customPattern: customPattern)
    }

    static func importedBook(source: TxtImportSource, sourceURL: URL? = nil, customPattern: String? = nil, selectedRule: TxtTocRule? = nil) -> ImportedBook {
        let result: TxtSplitResult
        if let selectedRule {
            result = TxtChapterSplitter.split(source.text, rule: selectedRule) ?? TxtChapterSplitter.chooseBest(source.text)
        } else if let customPattern, !customPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let custom = TxtChapterSplitter.split(source.text, customRegex: customPattern) {
            result = custom
        } else {
            result = TxtChapterSplitter.chooseBest(source.text)
        }
        let chapters = result.chapters.map { item in ImportedChapter(title: item.title, href: "txt:\(item.index)", text: item.content) }
        return ImportedBook(title: source.title, sourceType: "TXT", sourceURL: sourceURL, chapters: chapters)
    }

    /// BOM first, then strict UTF-8, then legacy Chinese encodings / UTF-16 candidates ranked by
    /// decoded-text quality. This mirrors Android's detector+fallback behavior without accepting a
    /// merely-decodable but obviously binary/garbled candidate.
    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return "" }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8).map(normalize)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian).map(normalize)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian).map(normalize)
        }
        // A fully valid UTF-8 stream is unambiguous enough to win before legacy code pages.
        if let utf8 = String(data: data, encoding: .utf8), quality(utf8) > 0.72 { return normalize(utf8) }

        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        var candidates: [(String, Double, Int)] = []
        for (index, encoding) in [gb18030, big5, .utf16LittleEndian, .utf16BigEndian].enumerated() {
            guard let decoded = String(data: data, encoding: encoding), !decoded.isEmpty else { continue }
            let q = quality(decoded)
            // Slightly prefer GB18030 over Big5, and legacy multibyte over BOM-less UTF-16 when
            // quality is effectively tied. Actual UTF-16 receives a strong null-byte signal below.
            let utf16Signal = (encoding == .utf16LittleEndian || encoding == .utf16BigEndian) ? utf16Likelihood(data, littleEndian: encoding == .utf16LittleEndian) : 0
            candidates.append((decoded, q + utf16Signal, index))
        }
        return candidates.max { lhs, rhs in
            if abs(lhs.1 - rhs.1) > 0.001 { return lhs.1 < rhs.1 }
            return lhs.2 > rhs.2
        }.map { normalize($0.0) }
    }

    /// Kept for callers/tests that need direct splitting.
    static func split(text: String, pattern: String? = nil) -> [ImportedChapter] {
        let result = pattern.flatMap { TxtChapterSplitter.split(text, customRegex: $0) } ?? TxtChapterSplitter.chooseBest(text)
        return result.chapters.map { .init(title: $0.title, href: "txt:\($0.index)", text: $0.content) }
    }

    private static func normalize(_ text: String) -> String {
        text.removingPrefix("\u{FEFF}")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func quality(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var printable = 0, controls = 0, replacements = 0, nul = 0, cjk = 0
        let scalars = text.unicodeScalars
        for s in scalars {
            switch s.value {
            case 0: nul += 1
            case 0xFFFD: replacements += 1
            case 0x0000...0x0008, 0x000B, 0x000C, 0x000E...0x001F, 0x007F: controls += 1
            default: printable += 1
            }
            if (0x3400...0x9FFF).contains(s.value) || (0xF900...0xFAFF).contains(s.value) { cjk += 1 }
        }
        let total = Double(max(1, scalars.count))
        let visible = Double(printable) / total
        let bad = Double(controls * 4 + replacements * 8 + nul * 12) / total
        let chineseBonus = min(0.08, Double(cjk) / total * 0.12)
        let lineBonus = text.contains("\n") ? 0.015 : 0
        return visible - bad + chineseBonus + lineBonus
    }

    /// BOM-less UTF-16 prose usually has NUL bytes concentrated on one byte lane for ASCII-heavy
    /// punctuation/metadata. This signal only breaks ties; it never overrides poor decoded text.
    private static func utf16Likelihood(_ data: Data, littleEndian: Bool) -> Double {
        guard data.count >= 8 else { return 0 }
        let sample = data.prefix(4096)
        var expected = 0, opposite = 0, pairs = 0
        var i = sample.startIndex
        while i < sample.endIndex {
            let j = sample.index(after: i)
            guard j < sample.endIndex else { break }
            let a = sample[i], b = sample[j]
            let zeroExpected = littleEndian ? b == 0 : a == 0
            let zeroOpposite = littleEndian ? a == 0 : b == 0
            if zeroExpected { expected += 1 }
            if zeroOpposite { opposite += 1 }
            pairs += 1
            i = sample.index(after: j)
        }
        guard pairs > 0 else { return 0 }
        let dominance = Double(expected - opposite) / Double(pairs)
        return max(0, dominance) * 0.20
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self }
}
