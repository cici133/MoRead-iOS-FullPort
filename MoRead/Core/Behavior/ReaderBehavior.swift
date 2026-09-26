import Foundation

enum PageMode: String, Codable, CaseIterable, Sendable { case scroll = "SCROLL", page = "PAGE" }

struct AutoReadSettings: Codable, Equatable, Sendable {
    var mode: PageMode = .scroll
    var scrollDpPerSecond: Double = 24
    var pageIntervalSeconds: Int = 15
    var showGuide = false

    func normalized() -> Self {
        var copy = self
        copy.scrollDpPerSecond = scrollDpPerSecond.isFinite ? min(96, max(8, scrollDpPerSecond)) : 24
        copy.pageIntervalSeconds = min(120, max(3, pageIntervalSeconds))
        return copy
    }
}

enum ChineseConversionMode: String, Codable, CaseIterable, Sendable { case off = "OFF", tw2sp = "TW2SP", s2twp = "S2TWP" }

enum ReaderTapAction: String, Codable, CaseIterable, Sendable {
    case none = "NONE", previousPage = "PREVIOUS_PAGE", nextPage = "NEXT_PAGE", menu = "MENU"
    case contents = "CONTENTS", bookmarks = "BOOKMARKS", toggleBookmark = "TOGGLE_BOOKMARK", settings = "SETTINGS"
    case previousChapter = "PREVIOUS_CHAPTER", nextChapter = "NEXT_CHAPTER", search = "SEARCH"
    case toggleTranslations = "TOGGLE_TRANSLATIONS", englishLearning = "ENGLISH_LEARNING"

    var label: String {
        switch self {
        case .none: return "无操作"
        case .previousPage: return "上一页"
        case .nextPage: return "下一页"
        case .menu: return "菜单"
        case .contents: return "目录 / 人物"
        case .bookmarks: return "书签"
        case .toggleBookmark: return "添加 / 移除书签"
        case .settings: return "阅读设置"
        case .previousChapter: return "上一章"
        case .nextChapter: return "下一章"
        case .search: return "书内搜索"
        case .toggleTranslations: return "显示 / 隐藏译文"
        case .englishLearning: return "英语学习 / 词典"
        }
    }
}

struct ReaderTapZones: Codable, Equatable, Sendable {
    static let edgeFraction = 0.08
    static let defaultActions: [ReaderTapAction] = (0..<9).map { index in
        switch index % 3 { case 0: return .previousPage; case 1: return .menu; default: return .nextPage }
    } + Array(repeating: .none, count: 4)
    var actions: [ReaderTapAction] = defaultActions

    func actionAt(x: Double, y: Double, width: Double, height: Double) -> ReaderTapAction {
        actions.indices.contains(Self.indexAt(x: x, y: y, width: width, height: height))
            ? actions[Self.indexAt(x: x, y: y, width: width, height: height)] : .menu
    }

    static func indexAt(x: Double, y: Double, width: Double, height: Double) -> Int {
        let nx = min(0.999999, max(0, x / max(width, 1)))
        let ny = min(0.999999, max(0, y / max(height, 1)))
        if ny < edgeFraction { return 9 + Int(nx * 2) }
        if ny >= 1 - edgeFraction { return 11 + Int(nx * 2) }
        let row = min(2, max(0, Int((ny - edgeFraction) / (1 - 2 * edgeFraction) * 3)))
        return row * 3 + Int(nx * 3)
    }

    static func decode(_ raw: String?) -> ReaderTapZones? {
        guard let raw, !raw.isEmpty else { return nil }
        let entries = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard entries.count == 13 else { return nil }
        let decoded = entries.compactMap { ReaderTapAction(rawValue: String($0)) }
        guard decoded.count == 13, decoded.contains(.menu) else { return nil }
        return ReaderTapZones(actions: decoded)
    }

    func encode() -> String { actions.map(\.rawValue).joined(separator: ",") }
}

struct BookReadSpan: Equatable, Sendable { let charsBeforeChapter: Int64; let totalChars: Int64 }

struct BookReadProgressInput: Equatable, Sendable {
    var lastReadAt: Int64
    var reachedEnd: Bool
    var totalChapters: Int
    var lastReadChapterIndex: Int
    var lastReadCharOffset: Int
}

enum BookReadProgress {
    static func fraction(_ book: BookReadProgressInput, span: BookReadSpan?) -> Double {
        if book.lastReadAt == 0 { return 0 }
        if book.reachedEnd { return 1 }
        let total = span?.totalChars ?? 0
        if span == nil || total <= 0 {
            guard book.totalChapters > 0 else { return 0 }
            return min(1, max(0, Double(book.lastReadChapterIndex + 1) / Double(book.totalChapters)))
        }
        let consumed = (span?.charsBeforeChapter ?? 0) + Int64(max(0, book.lastReadCharOffset))
        return min(1, max(0, Double(consumed) / Double(total)))
    }

    static func percent(_ fraction: Double) -> Int {
        let value = min(1, max(0, fraction))
        if value >= 1 { return 100 }
        if value <= 0 { return 0 }
        return min(99, max(1, Int((value * 100).rounded())))
    }
}

struct ReadingScope: Equatable, Sendable, CustomStringConvertible {
    let maxChapterIndex: Int
    let maxCharOffset: Int
    static let wholeBook = ReadingScope(maxChapterIndex: Int.max, maxCharOffset: Int.max)
    var isWholeBook: Bool { self == .wholeBook }
    func allowsChapter(_ chapterIndex: Int) -> Bool { chapterIndex >= 0 && chapterIndex <= maxChapterIndex }
    func contains(_ other: ReadingScope) -> Bool {
        isWholeBook || maxChapterIndex > other.maxChapterIndex || (maxChapterIndex == other.maxChapterIndex && maxCharOffset >= other.maxCharOffset)
    }
    func intersect(_ other: ReadingScope) -> ReadingScope { contains(other) ? other : self }
    func allowsPosition(chapterIndex: Int, charOffset: Int) -> Bool {
        if chapterIndex < 0 { return false }
        if chapterIndex < maxChapterIndex { return true }
        if chapterIndex > maxChapterIndex { return false }
        return charOffset >= 0 && charOffset <= maxCharOffset
    }
    func allowsChunk(chapterIndex: Int, startCharOffset: Int, endCharOffset: Int) -> Bool {
        if chapterIndex < 0 { return false }
        if chapterIndex < maxChapterIndex { return true }
        if chapterIndex > maxChapterIndex { return false }
        if isWholeBook { return true }
        if startCharOffset < 0 || endCharOffset <= startCharOffset { return false }
        return endCharOffset <= maxCharOffset
    }
    func clampLastChapter(totalChapters: Int) -> Int {
        let last = max(totalChapters - 1, 0)
        return isWholeBook ? last : min(last, max(0, maxChapterIndex))
    }
    /// MoRead stores offsets as UTF-16 code units. This prevents slicing between a surrogate pair.
    func readableUTF16End(chapterIndex: Int, text: String) -> Int {
        guard allowsChapter(chapterIndex) else { return 0 }
        let units = Array(text.utf16)
        var end = chapterIndex == maxChapterIndex ? min(maxCharOffset, units.count) : units.count
        if end > 0 && end < units.count {
            let current = units[end], previous = units[end - 1]
            if (0xDC00...0xDFFF).contains(current) && (0xD800...0xDBFF).contains(previous) { end -= 1 }
        }
        return end
    }
    func readableText(chapterIndex: Int, text: String) -> String {
        let units = Array(text.utf16.prefix(readableUTF16End(chapterIndex: chapterIndex, text: text)))
        return String(decoding: units, as: UTF16.self)
    }
    static func upto(chapterIndex: Int, charOffset: Int) -> ReadingScope {
        .init(maxChapterIndex: max(0, chapterIndex), maxCharOffset: max(0, charOffset))
    }
    static func uptoProgress(book: Book) -> ReadingScope {
        .init(maxChapterIndex: max(0, book.maxReachedChapterIndex), maxCharOffset: max(0, book.maxReachedCharOffset))
    }
    var description: String { isWholeBook ? "ReadingScope.WholeBook" : "ReadingScope(maxChapterIndex=\(maxChapterIndex), maxCharOffset=\(maxCharOffset))" }
}

enum SleepTimerPlan: Equatable, Sendable { case minutes(Int), chapters(Int), endOfChapter }
struct SleepTimerState: Equatable, Sendable {
    let plan: SleepTimerPlan
    var remainingMillis: Int64?
    var remainingChapters: Int?
    var running = true
}
enum SleepTimerPlanner {
    static func start(_ plan: SleepTimerPlan) -> SleepTimerState {
        switch plan {
        case let .minutes(minutes): return .init(plan: plan, remainingMillis: Int64(max(1, minutes)) * 60_000, remainingChapters: nil)
        case let .chapters(chapters): return .init(plan: plan, remainingMillis: nil, remainingChapters: max(1, chapters))
        case .endOfChapter: return .init(plan: plan, remainingMillis: nil, remainingChapters: 1)
        }
    }
    static func tick(_ state: SleepTimerState, elapsedMillis: Int64, playing: Bool) -> SleepTimerState {
        guard playing, state.running, let remaining = state.remainingMillis else { return state }
        var copy = state; copy.remainingMillis = max(0, remaining - elapsedMillis); return copy
    }
    static func onChapterCompleted(_ state: SleepTimerState) -> SleepTimerState {
        guard let remaining = state.remainingChapters else { return state }
        var copy = state; copy.remainingChapters = max(0, remaining - 1); return copy
    }
    static func isExpired(_ state: SleepTimerState) -> Bool {
        if let remaining = state.remainingMillis { return remaining <= 0 }
        return (state.remainingChapters ?? 1) <= 0
    }
    static func label(_ state: SleepTimerState) -> String {
        if let remaining = state.remainingMillis { let s = remaining / 1000; return String(format: "%02lld:%02lld", s / 60, s % 60) }
        if let chapters = state.remainingChapters { return "还剩 \(chapters) 章" }
        return "定时"
    }
}

extension AudiobookCostEstimator {
    static func estimate(characterCounts: [Int], engines: [String], pricePerTenThousandChars: Double) -> AudiobookCostEstimate {
        let count = min(characterCounts.count, engines.count)
        var total = 0
        var aiChars = 0
        var aiSegments = 0
        for index in 0..<count {
            let chars = max(0, characterCounts[index])
            total += chars
            if engines[index].caseInsensitiveCompare("AI") == .orderedSame {
                aiChars += chars
                aiSegments += 1
            }
        }
        return .init(totalChars: total, segmentCount: count, aiSegmentCount: aiSegments,
                     systemSegmentCount: count - aiSegments,
                     estimatedCost: Double(aiChars) / 10_000 * max(0, pricePerTenThousandChars))
    }
}
