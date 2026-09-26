import Foundation
import OpenCC

/// Display text is allowed to differ from canonical text.mz, but every persistent coordinate in
/// MoRead remains a UTF-16 offset in the canonical source. This mapping bridges both spaces.
struct ReaderTextMapping: Equatable, Sendable {
    let source: String
    let display: String
    private let displayToSource: [Int]
    private let sourceToDisplay: [Int]

    init(source: String, display: String) {
        self.source = source
        self.display = display
        if source == display {
            let count = (source as NSString).length
            let identity = Array(0...count)
            self.displayToSource = identity
            self.sourceToDisplay = identity
            return
        }
        let built = Self.align(source: source, display: display)
        self.displayToSource = built.displayToSource
        self.sourceToDisplay = built.sourceToDisplay
    }

    func sourceOffset(forDisplayOffset offset: Int) -> Int {
        guard !displayToSource.isEmpty else { return 0 }
        return displayToSource[min(max(0, offset), displayToSource.count - 1)]
    }

    func displayOffset(forSourceOffset offset: Int) -> Int {
        guard !sourceToDisplay.isEmpty else { return 0 }
        return sourceToDisplay[min(max(0, offset), sourceToDisplay.count - 1)]
    }

    func sourceRange(displayStart: Int, displayEnd: Int) -> NSRange {
        let start = sourceOffset(forDisplayOffset: displayStart)
        let end = max(start, sourceOffset(forDisplayOffset: displayEnd))
        return NSRange(location: start, length: end - start)
    }

    private static func align(source: String, display: String) -> (displayToSource: [Int], sourceToDisplay: [Int]) {
        let sChars = Array(source)
        let dChars = Array(display)
        let sOffsets = utf16Boundaries(sChars)
        let dOffsets = utf16Boundaries(dChars)
        var d2s = Array(repeating: 0, count: (display as NSString).length + 1)
        var s2d = Array(repeating: 0, count: (source as NSString).length + 1)

        func fill(_ s0: Int, _ s1: Int, _ d0: Int, _ d1: Int) {
            let su0 = sOffsets[min(max(0, s0), sOffsets.count - 1)]
            let su1 = sOffsets[min(max(0, s1), sOffsets.count - 1)]
            let du0 = dOffsets[min(max(0, d0), dOffsets.count - 1)]
            let du1 = dOffsets[min(max(0, d1), dOffsets.count - 1)]
            let sLen = max(0, su1 - su0), dLen = max(0, du1 - du0)
            if dLen == 0 {
                if du0 < d2s.count { d2s[du0] = su0 }
            } else {
                for k in 0...dLen { d2s[du0 + k] = su0 + Int((Double(k) / Double(dLen) * Double(sLen)).rounded()) }
            }
            if sLen == 0 {
                if su0 < s2d.count { s2d[su0] = du0 }
            } else {
                for k in 0...sLen { s2d[su0 + k] = du0 + Int((Double(k) / Double(sLen) * Double(dLen)).rounded()) }
            }
        }

        var si = 0, di = 0
        let lookAhead = 24
        while si < sChars.count && di < dChars.count {
            if sChars[si] == dChars[di] {
                fill(si, si + 1, di, di + 1)
                si += 1; di += 1
                continue
            }
            var best: (a: Int, b: Int, score: Int)?
            let maxA = min(lookAhead, sChars.count - si - 1)
            let maxB = min(lookAhead, dChars.count - di - 1)
            if maxA >= 0 && maxB >= 0 {
                for a in 0...maxA {
                    for b in 0...maxB where a != 0 || b != 0 {
                        guard sChars[si + a] == dChars[di + b] else { continue }
                        let score = a + b + abs(a - b)
                        if best == nil || score < best!.score { best = (a, b, score) }
                    }
                }
            }
            if let best {
                fill(si, si + best.a, di, di + best.b)
                si += best.a; di += best.b
            } else {
                fill(si, sChars.count, di, dChars.count)
                si = sChars.count; di = dChars.count
            }
        }
        if si < sChars.count || di < dChars.count { fill(si, sChars.count, di, dChars.count) }
        if !d2s.isEmpty { d2s[d2s.count - 1] = (source as NSString).length }
        if !s2d.isEmpty { s2d[s2d.count - 1] = (display as NSString).length }
        // Interpolation can only be monotonic; enforce it so malformed/ambiguous conversions can
        // never move a reading position backwards.
        for i in 1..<d2s.count { d2s[i] = max(d2s[i], d2s[i - 1]) }
        for i in 1..<s2d.count { s2d[i] = max(s2d[i], s2d[i - 1]) }
        return (d2s, s2d)
    }

    private static func utf16Boundaries(_ characters: [Character]) -> [Int] {
        var result = [0]
        result.reserveCapacity(characters.count + 1)
        var total = 0
        for character in characters {
            total += String(character).utf16.count
            result.append(total)
        }
        return result
    }
}

/// Uses the same OpenCC modes as Android: TW2SP and S2TWP. Conversion failure is fail-open so a
/// missing package resource never makes a book unreadable.
final class ChineseTextConverter: @unchecked Sendable {
    static let shared = ChineseTextConverter()
    private let tw2sp: ChineseConverter?
    private let s2twp: ChineseConverter?

    private init() {
        tw2sp = try? ChineseConverter(options: [.simplify, .twStandard, .twIdiom])
        s2twp = try? ChineseConverter(options: [.traditionalize, .twStandard, .twIdiom])
    }

    func mapping(for text: String, mode: ChineseConversionMode) -> ReaderTextMapping {
        guard !text.isEmpty, mode != .off else { return ReaderTextMapping(source: text, display: text) }
        let converted: String
        switch mode {
        case .off:
            converted = text
        case .tw2sp:
            converted = tw2sp?.convert(text) ?? fallback(text, transform: "Traditional-Simplified")
        case .s2twp:
            converted = s2twp?.convert(text) ?? fallback(text, transform: "Simplified-Traditional")
        }
        return ReaderTextMapping(source: text, display: converted)
    }

    private func fallback(_ text: String, transform: String) -> String {
        text.applyingTransform(StringTransform(transform), reverse: false) ?? text
    }
}
