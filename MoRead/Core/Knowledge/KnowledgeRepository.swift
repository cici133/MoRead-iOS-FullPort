import Foundation

actor ChapterKnowledgeRepository {
    static let shared = ChapterKnowledgeRepository()
    private let db = MoReadDatabase.shared

    func knowledge(bookId: Int64, chapterIndex: Int, scope: ReadingScope) async throws -> ChapterKnowledge? {
        guard let row = try await db.rows("SELECT * FROM chapter_knowledge WHERE bookId=? AND chapterIndex=?", [.integer(bookId), .integer(Int64(chapterIndex))]).first else { return nil }
        let revision = try await LibraryRepository.shared.contentRevision(bookId: bookId)
        guard row["sourceRevision"]?.string == revision else { return nil }
        let sourceEnd = Int(row["sourceEnd"]?.int64 ?? 0)
        guard scope.allowsChunk(chapterIndex: chapterIndex, startCharOffset: 0, endCharOffset: sourceEnd),
              let raw = row["contentJson"]?.string,
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(ChapterKnowledge.self, from: data) else { return nil }
        return value
    }

    func generate(bookId: Int64, chapterIndex: Int, scope: ReadingScope) async throws -> ChapterKnowledge {
        guard let chapter = try await LibraryRepository.shared.chapter(bookId: bookId, index: chapterIndex) else { throw ChapterKnowledgeCodec.KnowledgeError.invalid("章节不存在") }
        let full = try await LibraryRepository.shared.chapterText(chapter)
        let source = scope.readableText(chapterIndex: chapterIndex, text: full)
        let revision = try await LibraryRepository.shared.contentRevision(bookId: bookId)
        let sourceHash = ChapterKnowledgeCodec.hash(source)
        let parts = try ChapterKnowledgeCodec.parts(source)
        let resolved = try await AIClientFactory.forRole(.cheap)
        var values: [ChapterKnowledge] = []
        for part in parts {
            let prompt = """
            整理这段小说原文。只输出 JSON：{"outline":"连贯自然段梗概","summary":[{"text":"事实","quote":"逐字原文"}],"characters":[{"name":"人物稳定称呼","facts":[{"text":"事实","quote":"逐字原文"}],"attributes":[{"kind":"ALIAS|AGE|GENDER|IDENTITY|APPEARANCE","value":"值","quote":"包含人物名的逐字原文"}],"relationships":[{"target":"另一人物","relation":"关系","quote":"同时包含双方称呼的逐字原文"}]}]}。所有 quote 必须逐字来自提供原文，禁止推测。
            原文：
            \(part.text)
            """
            let raw = try await resolved.client.chat(messages: [.init(role: .user, content: prompt)], options: resolved.options)
            values.append(try ChapterKnowledgeCodec.parse(raw, part: part))
        }
        var merged = ChapterKnowledgeCodec.merge(values)
        if values.count > 1 {
            let compact = merged.summary.map { "- \($0.text)（依据：\($0.quote)）" }.joined(separator: "\n")
            let prompt = "把下面多段摘要合成一篇连贯自然段梗概，不要列表，不添加未提供事实，限 2400 字：\n\(compact)"
            let outline = try await resolved.client.chat(messages: [.init(role: .user, content: prompt)], options: resolved.options)
            merged = .init(summary: merged.summary, characters: merged.characters, outline: try ChapterKnowledgeCodec.validateOutline(outline, limit: 2400))
        }
        let json = String(decoding: try JSONEncoder().encode(merged), as: UTF8.self)
        let now = Self.now()
        try await db.execute("INSERT INTO chapter_knowledge(bookId,chapterIndex,sourceRevision,sourceEnd,sourceHash,modelKey,modelLabel,promptVersion,contentJson,createdAt) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(bookId,chapterIndex) DO UPDATE SET sourceRevision=excluded.sourceRevision,sourceEnd=excluded.sourceEnd,sourceHash=excluded.sourceHash,modelKey=excluded.modelKey,modelLabel=excluded.modelLabel,promptVersion=excluded.promptVersion,contentJson=excluded.contentJson,createdAt=excluded.createdAt", [.integer(bookId), .integer(Int64(chapterIndex)), .text(revision), .integer(Int64((source as NSString).length)), .text(sourceHash), .text("\(resolved.provider.id):\(resolved.modelName)"), .text(resolved.modelName), .integer(Int64(ChapterKnowledgeCodec.promptVersion)), .text(json), .integer(now)])
        return merged
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

struct CharacterEvidence: Codable, Hashable, Sendable {
    var chapterIndex: Int
    var fact: KnowledgeFact
}

struct BookCharacterGuide: Codable, Hashable, Sendable {
    var characters: [KnowledgeCharacter]
    var uptoChapter: Int
    var uptoCharOffset: Int
    /// Evidence keeps chapter coordinates after characters from many chapters are merged.
    var evidenceByName: [String: [CharacterEvidence]]? = nil
    /// true means the extraction deliberately stopped at reading progress; false means full-book consent was used.
    var progressBounded: Bool? = true
}

struct CharacterScanPlan: Sendable {
    let bookId: Int64
    let bookTitle: String
    let revision: String
    let chapters: [Chapter]
    let scope: ReadingScope
    let progressBounded: Bool
    let sourceCharacters: Int64
    let reusableParts: Int
    let modelKey: String
    let modelLabel: String

    var scansUnread: Bool { !progressBounded }
    var chapterCount: Int { chapters.count }
    var estimatedMaximumRequests: Int64 {
        chapters.reduce(0) { total, chapter in
            let chars: Int
            if progressBounded, chapter.chapterIndex == scope.maxChapterIndex { chars = min(chapter.charCount, scope.maxCharOffset) }
            else { chars = chapter.charCount }
            return total + Int64(max(1, (chars + ChapterKnowledgeCodec.partUTF16 / 2 - 1) / (ChapterKnowledgeCodec.partUTF16 / 2)))
        }
    }
}

struct CharacterScanProgress: Sendable {
    let chapterNumber: Int
    let chapterCount: Int
    let chapterTitle: String
    let completedParts: Int
    let reusedParts: Int
}

actor BookCharacterRepository {
    static let shared = BookCharacterRepository()
    private let db = MoReadDatabase.shared

    func published(bookId: Int64, scope: ReadingScope? = nil, allowBeyondProgress: Bool = false) async throws -> BookCharacterGuide? {
        guard let row = try await db.rows("SELECT * FROM book_character_guides WHERE bookId=?", [.integer(bookId)]).first,
              let raw = row["contentJson"]?.string,
              let data = raw.data(using: .utf8),
              let guide = try? JSONDecoder().decode(BookCharacterGuide.self, from: data) else { return nil }
        let revision = try await LibraryRepository.shared.contentRevision(bookId: bookId)
        guard row["sourceRevision"]?.string == revision else { return nil }
        if let scope, !allowBeyondProgress, !scope.contains(.upto(chapterIndex: guide.uptoChapter, charOffset: guide.uptoCharOffset)) { return nil }
        return guide
    }

    /// Metadata-only preview. No chapter body is sent to a provider here.
    func preview(bookId: Int64, progressBounded: Bool) async throws -> CharacterScanPlan {
        guard let book = try await LibraryRepository.shared.book(id: bookId), book.removedAt == 0 else { throw ScanError("书籍正文已移除") }
        let all = try await LibraryRepository.shared.chapters(bookId: bookId).filter { $0.charCount > 0 }
        let scope = progressBounded ? ReadingScope.uptoProgress(book: book) : .wholeBook
        let chapters = progressBounded ? all.filter { chapter in
            scope.allowsChapter(chapter.chapterIndex) && (chapter.chapterIndex < scope.maxChapterIndex || scope.maxCharOffset > 0)
        } : all
        guard !chapters.isEmpty else { throw ScanError(progressBounded ? "还没有读过的正文可以提取" : "这本书没有可提取的正文") }
        let resolved = try await AIClientFactory.forRole(.cheap)
        let modelKey = ChapterKnowledgeCodec.hash("\(resolved.provider.id)|\(resolved.provider.baseURL)|\(resolved.modelName)|\(resolved.options)")
        let revision = try await LibraryRepository.shared.contentRevision(bookId: bookId)
        let reusable = Int(try await db.scalarInt("SELECT COUNT(*) FROM book_character_parts WHERE bookId=? AND sourceRevision=? AND modelKey=? AND promptVersion=?", [.integer(bookId), .text(revision), .text(modelKey), .integer(Int64(ChapterKnowledgeCodec.promptVersion))]) ?? 0)
        let chars = chapters.reduce(Int64(0)) { total, chapter in
            if progressBounded, chapter.chapterIndex == scope.maxChapterIndex { return total + Int64(min(chapter.charCount, scope.maxCharOffset)) }
            return total + Int64(chapter.charCount)
        }
        return .init(bookId: bookId, bookTitle: book.title, revision: revision, chapters: chapters, scope: scope, progressBounded: progressBounded, sourceCharacters: chars, reusableParts: reusable, modelKey: modelKey, modelLabel: resolved.modelName)
    }

    /// Cancellation leaves verified part rows intact, so a later run resumes by reusing them.
    func extract(plan: CharacterScanPlan, onProgress: @Sendable (CharacterScanProgress) async -> Void = { _ in }) async throws -> BookCharacterGuide {
        let resolved = try await AIClientFactory.forRole(.cheap)
        let generation = UUID().uuidString
        var merged: [KnowledgeCharacter] = []
        var evidence: [String: [CharacterEvidence]] = [:]
        var completed = 0
        var reused = 0

        for (chapterNumber, chapter) in plan.chapters.enumerated() {
            try Task.checkCancellation()
            try await validate(plan)
            let full = try await LibraryRepository.shared.chapterText(chapter)
            let source = plan.progressBounded ? plan.scope.readableText(chapterIndex: chapter.chapterIndex, text: full) : full
            if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let cachedRows = try await db.rows("SELECT * FROM book_character_parts WHERE bookId=? AND chapterIndex=?", [.integer(plan.bookId), .integer(Int64(chapter.chapterIndex))])
            let cached = Dictionary(uniqueKeysWithValues: cachedRows.compactMap { row -> (Int, [String: SQLValue])? in row["start"]?.int64.map { (Int($0), row) } })

            for part in try ChapterKnowledgeCodec.parts(source, enforceLimit: false) where !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try Task.checkCancellation()
                let partEnd = part.start + (part.text as NSString).length
                let hash = ChapterKnowledgeCodec.hash(part.text)
                var people: [KnowledgeCharacter]?
                if let row = cached[part.start], row["sourceRevision"]?.string == plan.revision, row["modelKey"]?.string == plan.modelKey,
                   Int(row["promptVersion"]?.int64 ?? 0) == ChapterKnowledgeCodec.promptVersion,
                   Int(row["end"]?.int64 ?? -1) == partEnd, row["sourceHash"]?.string == hash,
                   let raw = row["contentJson"]?.string, let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode([KnowledgeCharacter].self, from: data) {
                    people = decoded; reused += 1
                }
                if people == nil {
                    let prompt = """
                    从这段小说原文提取人物资料。只输出 JSON：{"outline":"人物提取","summary":[{"text":"本段明确事实","quote":"逐字原文"}],"characters":[{"name":"稳定称呼","facts":[{"text":"事实","quote":"逐字原文"}],"attributes":[{"kind":"ALIAS|AGE|GENDER|IDENTITY|APPEARANCE","value":"值","quote":"必须含人物名的逐字原文"}],"relationships":[{"target":"另一人物","relation":"关系","quote":"必须同时包含双方称呼的逐字原文"}]}]}。只能记录原文明确出现的信息，禁止推测；所有 quote 必须逐字来自原文。
                    书名：《\(plan.bookTitle)》
                    章节：\(chapter.title)
                    原文：
                    \(part.text)
                    """
                    let raw = try await resolved.client.chat(messages: [.init(role: .user, content: prompt)], options: resolved.options)
                    people = try ChapterKnowledgeCodec.parse(raw, part: part).characters
                    try await validate(plan)
                    let json = String(decoding: try JSONEncoder().encode(people ?? []), as: UTF8.self)
                    try await db.execute("INSERT INTO book_character_parts(bookId,chapterIndex,start,end,generationId,sourceRevision,sourceHash,modelKey,promptVersion,contentJson,createdAt) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(bookId,chapterIndex,start) DO UPDATE SET end=excluded.end,generationId=excluded.generationId,sourceRevision=excluded.sourceRevision,sourceHash=excluded.sourceHash,modelKey=excluded.modelKey,promptVersion=excluded.promptVersion,contentJson=excluded.contentJson,createdAt=excluded.createdAt", [.integer(plan.bookId), .integer(Int64(chapter.chapterIndex)), .integer(Int64(part.start)), .integer(Int64(partEnd)), .text(generation), .text(plan.revision), .text(hash), .text(plan.modelKey), .integer(Int64(ChapterKnowledgeCodec.promptVersion)), .text(json), .integer(Self.now())])
                }
                for person in people ?? [] {
                    merge(person, into: &merged)
                    for fact in person.facts { evidence[person.name, default: []].append(.init(chapterIndex: chapter.chapterIndex, fact: fact)) }
                    for attribute in person.attributes { evidence[person.name, default: []].append(.init(chapterIndex: chapter.chapterIndex, fact: attribute.fact)) }
                    for relationship in person.relationships { evidence[person.name, default: []].append(.init(chapterIndex: chapter.chapterIndex, fact: relationship.fact)) }
                }
                completed += 1
                await onProgress(.init(chapterNumber: chapterNumber + 1, chapterCount: plan.chapterCount, chapterTitle: chapter.title, completedParts: completed, reusedParts: reused))
            }
        }

        let last = plan.chapters.last!
        let uptoOffset = plan.progressBounded && last.chapterIndex == plan.scope.maxChapterIndex ? plan.scope.maxCharOffset : last.charCount
        let guide = BookCharacterGuide(characters: merged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, uptoChapter: last.chapterIndex, uptoCharOffset: uptoOffset, evidenceByName: evidence.mapValues { dedupeEvidence($0) }, progressBounded: plan.progressBounded)
        try await validate(plan)
        let raw = String(decoding: try JSONEncoder().encode(guide), as: UTF8.self)
        try await db.execute("INSERT INTO book_character_guides(bookId,generationId,sourceRevision,modelKey,modelLabel,promptVersion,contentJson,createdAt) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(bookId) DO UPDATE SET generationId=excluded.generationId,sourceRevision=excluded.sourceRevision,modelKey=excluded.modelKey,modelLabel=excluded.modelLabel,promptVersion=excluded.promptVersion,contentJson=excluded.contentJson,createdAt=excluded.createdAt", [.integer(plan.bookId), .text(generation), .text(plan.revision), .text(plan.modelKey), .text(plan.modelLabel), .integer(Int64(ChapterKnowledgeCodec.promptVersion)), .text(raw), .integer(Self.now())])
        return guide
    }

    func delete(bookId: Int64) async throws {
        try await db.transaction { database in
            try database.execute("DELETE FROM book_character_guides WHERE bookId=?", [.integer(bookId)])
            try database.execute("DELETE FROM book_character_parts WHERE bookId=?", [.integer(bookId)])
        }
    }

    func locate(bookId: Int64, evidence: CharacterEvidence) async throws -> (chapterIndex: Int, charOffset: Int) {
        guard let chapter = try await LibraryRepository.shared.chapter(bookId: bookId, index: evidence.chapterIndex) else { throw ScanError("原章节不存在") }
        let text = try await LibraryRepository.shared.chapterText(chapter) as NSString
        let start = evidence.fact.start, end = evidence.fact.end
        guard start >= 0, end > start, end <= text.length, text.substring(with: NSRange(location: start, length: end - start)) == evidence.fact.quote else { throw ScanError("无法核对这条原文，正文可能已经变化") }
        return (evidence.chapterIndex, start)
    }

    private func validate(_ plan: CharacterScanPlan) async throws {
        try Task.checkCancellation()
        guard let book = try await LibraryRepository.shared.book(id: plan.bookId), book.removedAt == 0 else { throw ScanError("原书已移除，本次提取已停止") }
        guard try await LibraryRepository.shared.contentRevision(bookId: plan.bookId) == plan.revision else { throw ScanError("正文已变化，请重新确认人物提取") }
    }

    private func merge(_ person: KnowledgeCharacter, into people: inout [KnowledgeCharacter]) {
        if let index = people.firstIndex(where: { $0.name == person.name }) {
            let old = people[index]
            people[index] = .init(name: old.name, facts: Array(Set(old.facts + person.facts)), attributes: Array(Set(old.attributes + person.attributes)), relationships: Array(Set(old.relationships + person.relationships)))
        } else { people.append(person) }
    }

    private func dedupeEvidence(_ rows: [CharacterEvidence]) -> [CharacterEvidence] {
        var seen = Set<String>()
        return rows.sorted { ($0.chapterIndex, $0.fact.start) < ($1.chapterIndex, $1.fact.start) }.filter { row in
            let key = "\(row.chapterIndex):\(row.fact.start):\(row.fact.end):\(row.fact.quote)"
            return seen.insert(key).inserted
        }
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    struct ScanError: LocalizedError { let text: String; init(_ text: String) { self.text = text }; var errorDescription: String? { text } }
}
