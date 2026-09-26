import Foundation

struct ReviewEntry: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case annotation, note }
    let id: String
    let kind: Kind
    let book: Book
    let personaId: Int64?
    let author: String
    let title: String
    let quote: String
    let body: String
    let timestamp: Int64
    let chapterIndex: Int?
    let charOffset: Int
    let annotation: ReaderAnnotation?
    let note: ReaderNote?

    var canLocate: Bool { book.removedAt == 0 && chapterIndex != nil }
    var kindLabel: String { kind == .annotation ? "划线" : "笔记" }
    var locationLabel: String { chapterIndex.map { "第 \($0 + 1) 章" } ?? "全书笔记" }
}

enum ReviewSourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部", mine = "我的", ai = "AI 伴读"
    var id: String { rawValue }
}

enum ReviewKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部内容", annotations = "划线与批注", notes = "读书笔记"
    var id: String { rawValue }
}

struct ReviewFilter: Sendable {
    var query = ""
    var bookId: Int64?
    var source: ReviewSourceFilter = .all
    var personaId: Int64?
    var kind: ReviewKindFilter = .all
    var oldestFirst = false
}

enum ReadingReviewLogic {
    static func entries(books: [Book], annotations: [ReaderAnnotation], notes: [ReaderNote], personas: [PersonaRecord], spoilerProtection: Bool = true) -> [ReviewEntry] {
        let bookMap = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        let personaMap = Dictionary(uniqueKeysWithValues: personas.map { ($0.id, $0) })
        func author(_ id: Int64?) -> String {
            guard let id else { return "我的" }
            return "AI · \(personaMap[id]?.name ?? "已删除角色")"
        }
        let highlights = annotations.compactMap { row -> ReviewEntry? in
            guard let book = bookMap[row.bookId] else { return nil }
            let scope = spoilerProtection ? ReadingScope.uptoProgress(book: book) : .wholeBook
            guard scope.allowsChunk(chapterIndex: row.chapterIndex, startCharOffset: row.startCharOffset, endCharOffset: row.endCharOffset) else { return nil }
            return .init(id: "highlight:\(row.id)", kind: .annotation, book: book, personaId: row.personaId, author: author(row.personaId), title: "", quote: row.selectedText, body: row.note, timestamp: row.createdAt, chapterIndex: row.chapterIndex, charOffset: row.startCharOffset, annotation: row, note: nil)
        }
        let writings = notes.compactMap { row -> ReviewEntry? in
            guard let book = bookMap[row.bookId] else { return nil }
            if spoilerProtection, row.personaId != nil {
                let scope = ReadingScope.uptoProgress(book: book)
                let chapter = row.sourceScopeChapterIndex ?? row.relatedChapterIndex
                let offset = row.sourceScopeCharOffset ?? row.relatedCharOffset
                let partial = (row.sourceScopeChapterIndex == nil) != (row.sourceScopeCharOffset == nil)
                if partial { return nil }
                if let chapter, let offset, !scope.allowsPosition(chapterIndex: chapter, charOffset: offset) { return nil }
                if (chapter == nil) != (offset == nil) { return nil }
            }
            return .init(id: "note:\(row.id)", kind: .note, book: book, personaId: row.personaId, author: author(row.personaId), title: row.title, quote: "", body: row.contentMarkdown, timestamp: row.updatedAt, chapterIndex: row.relatedChapterIndex, charOffset: row.relatedCharOffset ?? 0, annotation: nil, note: row)
        }
        return (highlights + writings).sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp { return lhs.id > rhs.id }
            return lhs.timestamp > rhs.timestamp
        }
    }

    static func filter(_ entries: [ReviewEntry], by filter: ReviewFilter) -> [ReviewEntry] {
        let words = filter.query.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        let rows = entries.filter { entry in
            if let bookId = filter.bookId, entry.book.id != bookId { return false }
            switch filter.source {
            case .all: break
            case .mine: if entry.personaId != nil { return false }
            case .ai:
                guard let pid = entry.personaId else { return false }
                if let wanted = filter.personaId, pid != wanted { return false }
            }
            switch filter.kind {
            case .all: break
            case .annotations: if entry.kind != .annotation { return false }
            case .notes: if entry.kind != .note { return false }
            }
            return words.allSatisfy { word in
                [entry.book.title, entry.book.author, entry.author, entry.title, entry.quote, entry.body].contains { $0.localizedCaseInsensitiveContains(word) }
            }
        }
        return filter.oldestFirst ? rows.reversed() : rows
    }

    static func markdown(_ entries: [ReviewEntry]) -> String {
        var output = "# 划线与笔记\n\n> 由墨知 MoRead 导出 · \(Date().formatted(date: .numeric, time: .shortened))\n\n"
        var seen: [Int64] = []
        for entry in entries where !seen.contains(entry.book.id) { seen.append(entry.book.id) }
        for bookId in seen {
            let group = entries.filter { $0.book.id == bookId }
            guard let first = group.first else { continue }
            output += "## \(first.book.title)\n\n"
            for entry in group {
                if !entry.title.isEmpty { output += "### \(entry.title)\n\n" }
                if !entry.quote.isEmpty { output += "> " + entry.quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n" }
                if !entry.body.isEmpty { output += entry.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" }
                output += "— \(entry.author) · \(entry.locationLabel)\n\n"
            }
        }
        return output
    }

    static let maxAISources = 20
    static let maxAISourceChars = 24_000

    static func aiSources(_ entries: [ReviewEntry], bookId: Int64) -> [ReviewEntry] {
        var remaining = maxAISourceChars
        var result: [ReviewEntry] = []
        for entry in entries where entry.book.id == bookId {
            if result.count >= maxAISources { break }
            let cost = (entry.title as NSString).length + (entry.quote as NSString).length + (entry.body as NSString).length + (entry.author as NSString).length + 100
            guard remaining - cost >= 0 else { break }
            remaining -= cost
            result.append(entry)
        }
        return result
    }

    static func aiSourceText(_ entries: [ReviewEntry]) -> String {
        entries.enumerated().map { index, entry in
            var block = "[\(index + 1)] \(entry.locationLabel) · \(entry.author)"
            if !entry.title.isEmpty { block += "\n标题：\(entry.title)" }
            if !entry.quote.isEmpty { block += "\n原文摘录：\(entry.quote)" }
            if !entry.body.isEmpty { block += "\n笔记 / 想法：\(entry.body)" }
            return block
        }.joined(separator: "\n\n")
    }
}

actor ReviewRepository {
    static let shared = ReviewRepository()

    func snapshot(spoilerProtection: Bool = true) async throws -> (entries: [ReviewEntry], books: [Book], personas: [PersonaRecord]) {
        async let books = LibraryRepository.shared.listBooks(includeRemoved: true)
        async let annotations = ReaderRecordRepository.shared.allAnnotations()
        async let notes = NoteRepository.shared.allNotes()
        async let personas = PersonaRepository.shared.personas()
        let values = try await (books, annotations, notes, personas)
        return (ReadingReviewLogic.entries(books: values.0, annotations: values.1, notes: values.2, personas: values.3, spoilerProtection: spoilerProtection), values.0, values.3)
    }

    func update(_ entry: ReviewEntry, title: String, body: String) async throws {
        switch entry.kind {
        case .annotation:
            guard let row = entry.annotation else { return }
            try await ReaderRecordRepository.shared.updateAnnotation(id: row.id, note: body, colorTag: row.colorTag, style: row.style)
        case .note:
            guard let row = entry.note else { return }
            try await NoteRepository.shared.update(id: row.id, title: title, content: body)
        }
    }

    func delete(_ entry: ReviewEntry) async throws {
        switch entry.kind {
        case .annotation:
            if let row = entry.annotation { try await ReaderRecordRepository.shared.deleteAnnotation(id: row.id) }
        case .note:
            if let row = entry.note { try await NoteRepository.shared.delete(id: row.id) }
        }
    }

    func exportMarkdown(_ entries: [ReviewEntry]) throws -> URL {
        let root = try MoReadDatabase.applicationDirectory().appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("MoRead-回顾-\(UUID().uuidString).md")
        try ReadingReviewLogic.markdown(entries).write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
