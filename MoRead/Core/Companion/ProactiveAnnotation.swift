import Foundation
import CryptoKit

struct ProactiveAnnotationParagraph: Hashable, Sendable {
    let start: Int
    let end: Int
}

enum ProactiveAnnotationParagraphs {
    static let maxPrefixChars = 28_000
    static let maxTargetChars = 1_800
    private static let heading = try! NSRegularExpression(pattern: "^(?:第.{1,20}[章节卷回]|序章|序言|序幕|楔子|前言|后记|尾声|chapter\\s+(?:[0-9]+|[ivxlcdm]+)\\b).*", options: [.caseInsensitive])

    static func isHeading(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return heading.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    static func split(_ body: String) -> [ProactiveAnnotationParagraph] {
        let ns = body as NSString
        var out: [ProactiveAnnotationParagraph] = []
        var cursor = 0
        for line in body.components(separatedBy: "\n") {
            let lns = line as NSString
            var first = 0
            while first < lns.length, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(lns.character(at: first))!) { first += 1 }
            var last = lns.length
            while last > first, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(lns.character(at: last - 1))!) { last -= 1 }
            let start = cursor + first
            let end = cursor + last
            if end - start >= 40 && !isHeading(line) {
                var partStart = start
                while partStart < end {
                    var boundary = min(partStart + maxTargetChars, end)
                    if boundary < end {
                        let floor = partStart + maxTargetChars / 2
                        var candidate: Int?
                        var i = boundary - 1
                        while i >= floor {
                            let u = ns.character(at: i)
                            if "。！？!?；;".utf16.contains(u) { candidate = i + 1; break }
                            i -= 1
                        }
                        if let candidate { boundary = candidate }
                        if end - boundary > 0 && end - boundary <= 5 { boundary = max(partStart + 6, boundary - (6 - (end - boundary))) }
                        if boundary > 0 && boundary < ns.length {
                            let a = ns.character(at: boundary - 1), b = ns.character(at: boundary)
                            if UTF16.isLeadSurrogate(a) && UTF16.isTrailSurrogate(b) { boundary -= 1 }
                        }
                    }
                    if boundary - partStart >= 6 { out.append(.init(start: partStart, end: boundary)) }
                    if boundary <= partStart { break }
                    partStart = boundary
                }
            }
            cursor += lns.length + 1
        }
        return out
    }

    static func candidates(_ body: String, limit: Int) -> [ProactiveAnnotationParagraph] {
        let all = split(body)
        let count = min(max(0, limit), all.count)
        guard count > 0 else { return [] }
        let ns = body as NSString
        var cursor = 0
        var result: [ProactiveAnnotationParagraph] = []
        for bucket in 0..<count {
            let boundary = Int64(ns.length) * Int64(bucket + 1) / Int64(count)
            let lastAllowed = all.count - (count - bucket - 1)
            var end = cursor + 1
            while end < lastAllowed && all[end - 1].end < Int(boundary) { end += 1 }
            let group = Array(all[cursor..<end])
            cursor = end
            let best = group.max { lhs, rhs in score(ns, lhs) < score(ns, rhs) }!
            result.append(best)
        }
        return result.sorted { $0.end < $1.end }
    }

    static func prefix(_ body: String, paragraph: ProactiveAnnotationParagraph, maxChars: Int = maxPrefixChars) -> String {
        let ns = body as NSString
        var start = min(paragraph.start, max(0, paragraph.end - max(0, maxChars)))
        if start > 0 && start < ns.length {
            let a = ns.character(at: start - 1), b = ns.character(at: start)
            if UTF16.isLeadSurrogate(a) && UTF16.isTrailSurrogate(b) { start += 1 }
        }
        return ns.substring(with: NSRange(location: start, length: max(0, paragraph.end - start)))
    }

    static func revision(_ body: String) -> String { SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined() }

    private static func score(_ ns: NSString, _ p: ProactiveAnnotationParagraph) -> Int {
        let text = ns.substring(with: NSRange(location: p.start, length: p.end - p.start))
        let punctuation = text.filter { "！!？?“”\"".contains($0) }.count
        return min(p.end - p.start, 300) + punctuation * 12
    }
}

enum ProactiveAnnotationTiming: String, Codable, CaseIterable, Sendable {
    case afterChapterComplete = "AFTER_CHAPTER_COMPLETE"
    case onChapterEntry = "ON_CHAPTER_ENTRY"

    var label: String {
        switch self {
        case .afterChapterComplete: return "读完一章后生成"
        case .onChapterEntry: return "进入章节时预生成"
        }
    }
}

struct ProactiveAnnotationLimits: Codable, Hashable, Sendable {
    static let unlimited = -1
    var minPerChapter = 1
    var maxPerChapter = 2
    var dailyMax = 10
    var dailyVoiceMax = 3
    var dailyImageMax = 3
    var timing: ProactiveAnnotationTiming = .afterChapterComplete
    var aheadChapters = 0
    var contextBudgetChars = 16_000

    init(
        minPerChapter: Int = 1,
        maxPerChapter: Int = 2,
        dailyMax: Int = 10,
        dailyVoiceMax: Int = 3,
        dailyImageMax: Int = 3,
        timing: ProactiveAnnotationTiming = .afterChapterComplete,
        aheadChapters: Int = 0,
        contextBudgetChars: Int = 16_000
    ) {
        self.minPerChapter = minPerChapter
        self.maxPerChapter = maxPerChapter
        self.dailyMax = dailyMax
        self.dailyVoiceMax = dailyVoiceMax
        self.dailyImageMax = dailyImageMax
        self.timing = timing
        self.aheadChapters = aheadChapters
        self.contextBudgetChars = contextBudgetChars
    }

    private enum CodingKeys: String, CodingKey {
        case minPerChapter, maxPerChapter, dailyMax, dailyVoiceMax, dailyImageMax, timing, aheadChapters, contextBudgetChars
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minPerChapter = try c.decodeIfPresent(Int.self, forKey: .minPerChapter) ?? 1
        maxPerChapter = try c.decodeIfPresent(Int.self, forKey: .maxPerChapter) ?? 2
        dailyMax = try c.decodeIfPresent(Int.self, forKey: .dailyMax) ?? 10
        dailyVoiceMax = try c.decodeIfPresent(Int.self, forKey: .dailyVoiceMax) ?? 3
        dailyImageMax = try c.decodeIfPresent(Int.self, forKey: .dailyImageMax) ?? 3
        timing = try c.decodeIfPresent(ProactiveAnnotationTiming.self, forKey: .timing) ?? .afterChapterComplete
        aheadChapters = try c.decodeIfPresent(Int.self, forKey: .aheadChapters) ?? 0
        contextBudgetChars = try c.decodeIfPresent(Int.self, forKey: .contextBudgetChars) ?? 16_000
    }

    func normalized() -> Self {
        var v = self
        v.maxPerChapter = v.maxPerChapter == Self.unlimited ? Self.unlimited : min(10, max(1, v.maxPerChapter))
        let ceiling = v.maxPerChapter == Self.unlimited ? 10 : v.maxPerChapter
        v.minPerChapter = min(ceiling, max(0, v.minPerChapter))
        v.dailyMax = v.dailyMax == Self.unlimited ? Self.unlimited : min(50, max(1, v.dailyMax))
        v.dailyVoiceMax = v.dailyVoiceMax == Self.unlimited ? Self.unlimited : min(50, max(0, v.dailyVoiceMax))
        v.dailyImageMax = v.dailyImageMax == Self.unlimited ? Self.unlimited : min(50, max(0, v.dailyImageMax))
        v.aheadChapters = min(5, max(0, v.aheadChapters))
        v.contextBudgetChars = min(64_000, max(4_000, v.contextBudgetChars))
        return v
    }
}


private struct ProactiveDraft: Codable, Sendable {
    var quote = ""
    var note = ""
    var style = "HIGHLIGHT"
    var voice = false
    var image_prompt: String? = nil
}

struct ProactiveAnnotationGenerationSummary: Sendable {
    var createdIds: [Int64] = []
    var dailyBudgetExhausted = false
    var stopped = false
}

actor ProactiveAnnotationService {
    static let shared = ProactiveAnnotationService()
    private let db = MoReadDatabase.shared

    func generate(
        bookId: Int64,
        chapterIndex: Int,
        personaId: Int64,
        personaName: String,
        personaPrompt: String,
        limits: ProactiveAnnotationLimits = .init(),
        allowUnreadSource: Bool = false,
        voiceEnabled: Bool = false,
        imagesEnabled: Bool = false,
        personaVoiceId: String = "",
        personaVoiceEmotion: String = ""
    ) async throws -> ProactiveAnnotationGenerationSummary {
        try Task.checkCancellation()
        guard let chapter = try await LibraryRepository.shared.chapter(bookId: bookId, index: chapterIndex),
              let book = try await LibraryRepository.shared.book(id: bookId), book.removedAt == 0 else { return .init(stopped: true) }

        let full = try await LibraryRepository.shared.chapterText(chapter)
        let scope = ReadingScope.uptoProgress(book: book)
        let body: String
        if allowUnreadSource {
            body = full
        } else {
            guard scope.allowsChapter(chapterIndex) else { return .init(stopped: true) }
            body = scope.readableText(chapterIndex: chapterIndex, text: full)
        }
        guard !body.isBlank else { return .init(stopped: true) }

        let revision = ProactiveAnnotationParagraphs.revision(body)
        let l = limits.normalized()
        let now = Self.now()
        let existing = try await db.rows(
            "SELECT * FROM proactive_annotation_jobs WHERE bookId=? AND chapterIndex=? AND personaId=? AND sourceRevision=? LIMIT 1",
            [.integer(bookId), .integer(Int64(chapterIndex)), .integer(personaId), .text(revision)]
        ).first
        if let existing {
            let status = existing["status"]?.string ?? ""
            let attempts = Int(existing["attempts"]?.int64 ?? 0)
            let updatedAt = existing["updatedAt"]?.int64 ?? 0
            if status == "DONE" || attempts >= 2 { return .init() }
            if status == "PENDING", now - updatedAt < 10 * 60_000 { return .init(stopped: true) }
        }

        var done = Set((existing?["doneParagraphEnds"]?.string ?? "").split(separator: ",").compactMap { Int($0) })
        let jobId: Int64
        if let id = existing?["id"]?.int64 {
            jobId = id
            try await db.execute(
                "UPDATE proactive_annotation_jobs SET status='PENDING',failureReason=NULL,updatedAt=? WHERE id=?",
                [.integer(now), .integer(id)]
            )
        } else {
            jobId = try await db.execute(
                "INSERT INTO proactive_annotation_jobs(bookId,chapterIndex,personaId,sourceRevision,status,attempts,doneParagraphEnds,failureReason,createdAt,updatedAt) VALUES(?,?,?,?,?,?,?,?,?,?)",
                [.integer(bookId), .integer(Int64(chapterIndex)), .integer(personaId), .text(revision), .text("PENDING"), .integer(0), .text(""), .null, .integer(now), .integer(now)]
            )
        }

        let initialAllowance = try await remainingDailyAllowance(limits: l)
        if initialAllowance <= 0 {
            try await finish(jobId, status: "PAUSED", done: done, reason: "daily_limit", incrementFailure: false)
            return .init(dailyBudgetExhausted: true, stopped: true)
        }
        let chapterCap = l.maxPerChapter == ProactiveAnnotationLimits.unlimited ? Int.max : l.maxPerChapter
        if done.count >= chapterCap {
            try await finish(jobId, status: "DONE", done: done, reason: nil, incrementFailure: false)
            return .init()
        }
        let candidateLimit = min(chapterCap, initialAllowance)
        let resolved = try await AIClientFactory.forRole(.proactiveAnnotation)
        let paragraphs = ProactiveAnnotationParagraphs.candidates(body, limit: min(candidateLimit, 10_000))
        let ns = body as NSString
        var created: [Int64] = []
        var generationFailed = false
        var budgetExhausted = false

        for paragraph in paragraphs where !done.contains(paragraph.end) {
            try Task.checkCancellation()
            if done.count >= chapterCap { break }
            if try await remainingDailyAllowance(limits: l) <= 0 { budgetExhausted = true; break }

            let prefix = ProactiveAnnotationParagraphs.prefix(body, paragraph: paragraph, maxChars: l.contextBudgetChars)
            let target = ns.substring(with: NSRange(location: paragraph.start, length: paragraph.end - paragraph.start))
            let prompt = """
            你是“\(personaName)”并正陪用户阅读。角色口吻：\(String(personaPrompt.prefix(2400)))
            【共读身份】你和用户都在书外一起阅读。正文人物、第一/第二人称和经历属于作品，不能当成用户本人。
            只针对“唯一目标段落”写一条页边段评；只根据给出的正文前缀，不得猜测后文。
            quote 必须逐字复制自唯一目标段落，不能引用前面的段落；style 只能是 HIGHLIGHT、WAVY、UNDERLINE。
            本章期望至少 \(l.minPerChapter) 条，由应用逐段调度；本次只输出一条。
            只输出 JSON：{"quote":"逐字原文","note":"段评","style":"HIGHLIGHT|WAVY|UNDERLINE","voice":false,"image_prompt":null}
            正文前缀：
            \(prefix)

            唯一目标段落：
            \(target)
            """
            do {
                let raw = try await resolved.client.chat(messages: [.init(role: .user, content: prompt)], options: resolved.options)
                try Task.checkCancellation()
                guard let draft = decodeDraft(raw), draft.quote.utf16.count >= 6, !draft.note.isBlank else { generationFailed = true; continue }
                let tns = target as NSString
                let found = tns.range(of: draft.quote)
                guard found.location != NSNotFound else { generationFailed = true; continue }
                let after = NSMaxRange(found)
                let duplicate = after < tns.length && tns.range(of: draft.quote, options: [], range: NSRange(location: after, length: tns.length - after)).location != NSNotFound
                guard !duplicate else { generationFailed = true; continue }

                // Validate source again immediately before the durable write. A text mutation or a
                // reader-scope shrink must not publish a quote against stale coordinates.
                guard let currentBook = try await LibraryRepository.shared.book(id: bookId), currentBook.removedAt == 0,
                      let currentChapter = try await LibraryRepository.shared.chapter(bookId: bookId, index: chapterIndex) else {
                    try await finish(jobId, status: "PAUSED", done: done, reason: "source_removed", incrementFailure: false)
                    return .init(createdIds: created, stopped: true)
                }
                let currentFull = try await LibraryRepository.shared.chapterText(currentChapter)
                let currentBody = allowUnreadSource ? currentFull : ReadingScope.uptoProgress(book: currentBook).readableText(chapterIndex: chapterIndex, text: currentFull)
                guard ProactiveAnnotationParagraphs.revision(currentBody) == revision else {
                    try await finish(jobId, status: "PAUSED", done: done, reason: "source_changed", incrementFailure: false)
                    return .init(createdIds: created, stopped: true)
                }

                let start = paragraph.start + found.location
                let end = start + found.length
                var media = AnnotationMediaPayload()
                if voiceEnabled, draft.voice, !personaVoiceId.isEmpty,
                   await ProactiveAnnotationQuotaStore.shared.reserve(.voice, limit: l.dailyVoiceMax) {
                    if let url = try? await CloudSpeechService.shared.cachedSpeech(
                        text: draft.note,
                        voice: personaVoiceId,
                        bookId: bookId
                    ) { media.audioPath = url.path }
                }
                var detachedIllustration: GeneratedIllustration?
                if imagesEnabled, let imagePrompt = draft.image_prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !imagePrompt.isEmpty,
                   await ProactiveAnnotationQuotaStore.shared.reserve(.image, limit: l.dailyImageMax) {
                    var recipe = ImageRecipe()
                    recipe.shot = .init(action: imagePrompt)
                    detachedIllustration = try? await ImageGenerationService.shared.generate(
                        bookId: bookId,
                        chapterIndex: chapterIndex,
                        charOffset: start,
                        sourceText: draft.quote,
                        recipe: recipe,
                        personaId: personaId,
                        persist: false
                    )
                    if let detachedIllustration {
                        media.illustrationId = try? await ImageGenerationService.shared.insert(detachedIllustration)
                    }
                }
                do {
                    let id = try await ReaderRecordRepository.shared.addAnnotation(
                        bookId: bookId,
                        chapterIndex: chapterIndex,
                        start: start,
                        end: end,
                        text: ns.substring(with: NSRange(location: start, length: end - start)),
                        note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                        style: normalizeStyle(draft.style),
                        personaId: personaId,
                        sourceScope: .upto(chapterIndex: chapterIndex, charOffset: paragraph.end),
                        proactiveJobId: jobId,
                        mediaJSON: media.json()
                    )
                    created.append(id)
                } catch {
                    if let illustrationId = media.illustrationId { try? await ImageGenerationService.shared.delete(id: illustrationId) }
                    throw error
                }
                done.insert(paragraph.end)
                try await db.execute(
                    "UPDATE proactive_annotation_jobs SET doneParagraphEnds=?,status='PENDING',failureReason=NULL,updatedAt=? WHERE id=?",
                    [.text(done.sorted().map(String.init).joined(separator: ",")), .integer(Self.now()), .integer(jobId)]
                )
            } catch is CancellationError {
                try? await finish(jobId, status: "PENDING", done: done, reason: "cancelled", incrementFailure: false)
                throw CancellationError()
            } catch {
                generationFailed = true
            }
        }

        if budgetExhausted {
            try await finish(jobId, status: "PAUSED", done: done, reason: "daily_limit", incrementFailure: false)
        } else if generationFailed {
            try await finish(jobId, status: "FAILED", done: done, reason: "generation_failed", incrementFailure: true)
        } else {
            try await finish(jobId, status: "DONE", done: done, reason: nil, incrementFailure: false)
        }
        return .init(createdIds: created, dailyBudgetExhausted: budgetExhausted, stopped: budgetExhausted)
    }

    private func remainingDailyAllowance(limits: ProactiveAnnotationLimits) async throws -> Int {
        guard limits.dailyMax != ProactiveAnnotationLimits.unlimited else { return Int.max }
        let start = Calendar.current.startOfDay(for: Date())
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        // Android quota is global for proactive annotations, not per book.
        let count = try await db.scalarInt(
            "SELECT COUNT(*) FROM annotations WHERE proactiveJobId IS NOT NULL AND createdAt>=?",
            [.integer(startMs)]
        ) ?? 0
        return max(0, limits.dailyMax - Int(count))
    }

    private func finish(_ jobId: Int64, status: String, done: Set<Int>, reason: String?, incrementFailure: Bool) async throws {
        let attemptsSQL = incrementFailure ? "attempts=attempts+1," : ""
        try await db.execute(
            "UPDATE proactive_annotation_jobs SET status=?,doneParagraphEnds=?,\(attemptsSQL)failureReason=?,updatedAt=? WHERE id=?",
            [.text(status), .text(done.sorted().map(String.init).joined(separator: ",")), reason.map(SQLValue.text) ?? .null, .integer(Self.now()), .integer(jobId)]
        )
    }

    private func decodeDraft(_ raw: String) -> ProactiveDraft? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = clean.data(using: .utf8) else { return nil }
        if let value = try? JSONDecoder().decode(ProactiveDraft.self, from: data) { return value }
        if let values = try? JSONDecoder().decode([ProactiveDraft].self, from: data) { return values.first }
        return nil
    }

    private func normalizeStyle(_ raw: String) -> String {
        ["HIGHLIGHT", "WAVY", "UNDERLINE"].contains(raw.uppercased()) ? raw.uppercased() : "HIGHLIGHT"
    }

    private static func now() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}

private extension String { var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
