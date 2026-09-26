import Foundation
import UIKit

actor LibraryRepository {
    static let shared = LibraryRepository()
    private let database = MoReadDatabase.shared
    private let textStore = BookTextStore.shared

    func listBooks(includeRemoved: Bool = false) async throws -> [Book] {
        let whereClause = includeRemoved ? "" : "WHERE b.removedAt = 0"
        let rows = try await database.rows("""
            SELECT b.*,
              COALESCE((SELECT SUM(c.charCount) FROM chapters c WHERE c.bookId=b.id),0) AS totalChars,
              COALESCE((SELECT SUM(c.charCount) FROM chapters c WHERE c.bookId=b.id AND c.chapterIndex < b.lastReadChapterIndex),0) AS charsBeforeLastChapter
            FROM books b \(whereClause)
            ORDER BY CASE WHEN b.pinnedAt > 0 THEN 0 ELSE 1 END, b.pinnedAt DESC, b.lastReadAt DESC, b.importedAt DESC
            """)
        return rows.compactMap(Self.book)
    }

    func book(id: Int64) async throws -> Book? {
        let rows = try await database.rows("""
            SELECT b.*,
              COALESCE((SELECT SUM(c.charCount) FROM chapters c WHERE c.bookId=b.id),0) AS totalChars,
              COALESCE((SELECT SUM(c.charCount) FROM chapters c WHERE c.bookId=b.id AND c.chapterIndex < b.lastReadChapterIndex),0) AS charsBeforeLastChapter
            FROM books b WHERE b.id=? LIMIT 1
            """, [.integer(id)])
        return rows.first.flatMap(Self.book)
    }

    func chapters(bookId: Int64) async throws -> [Chapter] {
        try await database.rows("SELECT * FROM chapters WHERE bookId=? ORDER BY chapterIndex", [.integer(bookId)]).compactMap(Self.chapter)
    }

    func chapter(bookId: Int64, index: Int) async throws -> Chapter? {
        try await database.rows("SELECT * FROM chapters WHERE bookId=? AND chapterIndex=? LIMIT 1", [.integer(bookId), .integer(Int64(index))]).first.flatMap(Self.chapter)
    }

    func chapterText(_ chapter: Chapter) async throws -> String {
        try await textStore.readChapter(bookId: chapter.bookId, byteOffset: chapter.textByteOffset, byteLength: chapter.textByteLength)
    }

    func importBook(_ draft: ImportedBook) async throws -> Book {
        guard !draft.chapters.isEmpty else { throw ImportError.noChapters }
        let now = Self.nowMillis()
        let bookId = try await database.execute("""
            INSERT INTO books(title,author,coverPath,epubPath,sourceType,importedAt,totalChapters,lastReadLocator,lastReadChapterIndex,lastReadCharOffset,maxReachedChapterIndex,maxReachedCharOffset,lastReadAt,textVersion,tags,metadataEdited,manualReadState,reachedEnd,pinnedAt,groupId,collectionId,collectionOrder,removedAt)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(draft.title), .text(draft.author), .null, .text(""), .text(draft.sourceType), .integer(now), .integer(Int64(draft.chapters.count)),
                .null, .integer(0), .integer(0), .integer(0), .integer(0), .integer(0), .integer(1), .text(""), .integer(0), .null, .integer(0), .integer(0), .null, .null, .integer(0), .integer(0)
            ])
        do {
            let ranges = try await textStore.write(bookId: bookId, chapters: draft.chapters.enumerated().map { .init(index: $0.offset, body: $0.element.text) })
            let sourcePath = try copyOriginalSourceIfNeeded(draft.sourceURL, type: draft.sourceType, bookId: bookId)
            let importedCoverPath = try persistImportedCover(draft.coverData, fileExtension: draft.coverFileExtension, bookId: bookId)
            if draft.sourceType.uppercased() == "EPUB", !sourcePath.isEmpty {
                _ = try await EPUBResourceStore.shared.prepare(bookId: bookId, epubURL: URL(fileURLWithPath: sourcePath))
            }
            try await database.transaction { db in
                if !sourcePath.isEmpty { try db.execute("UPDATE books SET epubPath=? WHERE id=?", [.text(sourcePath), .integer(bookId)]) }
                if let importedCoverPath { try db.execute("UPDATE books SET coverPath=? WHERE id=?", [.text(importedCoverPath), .integer(bookId)]) }
                for (index, item) in draft.chapters.enumerated() {
                    guard let range = ranges.first(where: { $0.index == index }) else { continue }
                    try db.execute("INSERT INTO chapters(bookId,chapterIndex,title,href,charCount,textByteOffset,textByteLength) VALUES(?,?,?,?,?,?,?)", [
                        .integer(bookId), .integer(Int64(index)), .text(item.title), .text(item.href), .integer(Int64(range.charCount)), .integer(range.byteOffset), .integer(Int64(range.byteLength))
                    ])
                }
                for entry in draft.toc {
                    try db.execute("INSERT INTO book_toc_entries(bookId,orderIndex,title,href,depth,parentOrderIndex,chapterIndex,hasChildren) VALUES(?,?,?,?,?,?,?,?)", [
                        .integer(bookId), .integer(Int64(entry.orderIndex)), .text(entry.title), .text(entry.href), .integer(Int64(entry.depth)),
                        entry.parentOrderIndex.map { .integer(Int64($0)) } ?? .null,
                        entry.chapterIndex.map { .integer(Int64($0)) } ?? .null,
                        .integer(entry.hasChildren ? 1 : 0)
                    ])
                }
            }
            return try await book(id: bookId) ?? { throw ImportError.database }()
        } catch {
            try? await database.execute("DELETE FROM books WHERE id=?", [.integer(bookId)])
            try? await textStore.delete(bookId: bookId)
            try? FileManager.default.removeItem(at: AppPaths.booksRoot.appendingPathComponent(String(bookId), isDirectory: true))
            if let covers = try? FileManager.default.contentsOfDirectory(at: AppPaths.covers, includingPropertiesForKeys: nil) {
                for file in covers where file.lastPathComponent.hasPrefix("imported-\(bookId).") { try? FileManager.default.removeItem(at: file) }
            }
            throw error
        }
    }

    func updateProgress(bookId: Int64, chapterIndex: Int, charOffset: Int, reachedEnd: Bool = false) async throws {
        let now = Self.nowMillis()
        let row = try await database.rows("SELECT maxReachedChapterIndex,maxReachedCharOffset FROM books WHERE id=?", [.integer(bookId)]).first
        let currentChapter = Int(row?["maxReachedChapterIndex"]?.int64 ?? 0)
        let currentOffset = Int(row?["maxReachedCharOffset"]?.int64 ?? 0)
        let advances = chapterIndex > currentChapter || (chapterIndex == currentChapter && charOffset > currentOffset)
        let maxChapter = advances ? chapterIndex : currentChapter
        let maxOffset = advances ? max(0, charOffset) : currentOffset
        try await database.execute("UPDATE books SET lastReadChapterIndex=?,lastReadCharOffset=?,maxReachedChapterIndex=?,maxReachedCharOffset=?,lastReadAt=?,reachedEnd=? WHERE id=?", [
            .integer(Int64(max(0, chapterIndex))), .integer(Int64(max(0, charOffset))), .integer(Int64(maxChapter)), .integer(Int64(maxOffset)), .integer(now), .integer(reachedEnd ? 1 : 0), .integer(bookId)
        ])
    }

    func recordReading(bookId: Int64, durationMs: Int64, recordedAt: Int64 = nowMillis(), calendar: Calendar = .current) async throws {
        for slice in ReadingTimeSlicer.slices(durationMs: durationMs, recordedAt: recordedAt, calendar: calendar) {
            try await database.transaction { db in
                try db.execute("""
                    INSERT INTO reading_daily(bookId,epochDay,durationMs,lastReadAt) VALUES(?,?,?,?)
                    ON CONFLICT(bookId,epochDay) DO UPDATE SET durationMs=durationMs+excluded.durationMs,lastReadAt=MAX(lastReadAt,excluded.lastReadAt)
                    """, [.integer(bookId), .integer(slice.epochDay), .integer(slice.durationMs), .integer(slice.lastReadAt)])
                try db.execute("""
                    INSERT INTO reading_hourly(bookId,epochDay,hour,durationMs) VALUES(?,?,?,?)
                    ON CONFLICT(bookId,epochDay,hour) DO UPDATE SET durationMs=durationMs+excluded.durationMs
                    """, [.integer(bookId), .integer(slice.epochDay), .integer(Int64(slice.hour)), .integer(slice.durationMs)])
            }
        }
    }

    func softRemove(bookId: Int64) async throws {
        guard let current = try await book(id: bookId) else { return }
        try await database.transaction { db in
            try db.execute("UPDATE books SET removedAt=? WHERE id=?", [.integer(Self.nowMillis()), .integer(bookId)])
            try db.execute("DELETE FROM proactive_annotation_jobs WHERE bookId=?", [.integer(bookId)])
        }
        try? await removeContentFiles(for: current)
    }

    func permanentlyDelete(bookId: Int64) async throws {
        guard let current = try await book(id: bookId) else { return }
        let conversationRows = try await database.rows("SELECT id FROM conversations WHERE bookId=?", [.integer(bookId)])
        let conversationIds = Set(conversationRows.compactMap { $0["id"]?.int64 })
        let illustrationPaths = try await database.rows("SELECT imagePath FROM illustrations WHERE bookId=?", [.integer(bookId)]).compactMap { $0["imagePath"]?.string }
        let attachmentJSON = try await database.rows("""
            SELECT m.attachmentsJson FROM messages m
            JOIN conversations c ON c.id=m.conversationId
            WHERE c.bookId=? AND m.attachmentsJson IS NOT NULL
            """, [.integer(bookId)]).compactMap { $0["attachmentsJson"]?.string }
        let attachmentPaths = attachmentJSON.flatMap(Self.attachmentPaths)
        try await database.execute("DELETE FROM books WHERE id=?", [.integer(bookId)])
        try? await removeContentFiles(for: current)
        try? await VectorIndexStore.shared.remove(bookId: bookId)
        try? await MemoryRepository.shared.remove(bookId: bookId)
        try? await MemoryRepository.shared.remove(conversationIds: conversationIds)
        for path in Set(illustrationPaths + attachmentPaths) { Self.deleteManagedFile(path) }
        if let cover = current.coverPath { Self.deleteManagedFile(cover, excludingRoot: AppPaths.imageLibrary) }
        for url in [
            AppPaths.illustrations.appendingPathComponent(String(bookId), isDirectory: true),
            AppPaths.attachments.appendingPathComponent(String(bookId), isDirectory: true)
        ] { try? FileManager.default.removeItem(at: url) }
    }

    private func removeContentFiles(for book: Book) async throws {
        try? await textStore.delete(bookId: book.id)
        try? await VectorIndexStore.shared.remove(bookId: book.id)
        let roots = [
            AppPaths.booksRoot.appendingPathComponent(String(book.id), isDirectory: true),
            AppPaths.bookTextRoot.appendingPathComponent(String(book.id), isDirectory: true),
            AppPaths.bookMediaRoot.appendingPathComponent(String(book.id), isDirectory: true),
            AppPaths.bookLayoutRoot.appendingPathComponent(String(book.id), isDirectory: true),
            AppPaths.speechCache(bookId: book.id)
        ]
        for url in roots { try? FileManager.default.removeItem(at: url) }
        if !book.epubPath.isEmpty { Self.deleteManagedFile(book.epubPath) }
    }

    private static func attachmentPaths(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { $0["path"] as? String }
    }

    private static func deleteManagedFile(_ path: String, excludingRoot: URL? = nil) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let root = try? MoReadDatabase.applicationDirectory().standardizedFileURL, url.path.hasPrefix(root.path + "/") else { return }
        if let excludingRoot, url.path.hasPrefix(excludingRoot.standardizedFileURL.path + "/") { return }
        try? FileManager.default.removeItem(at: url)
    }

    struct TextCleanupChange: Identifiable, Sendable {
        var id: Int { chapterIndex }
        var chapterIndex: Int
        var title: String
        var before: String
        var after: String
    }
    struct TextCleanupPreview: Sendable {
        var revision: String
        var matchCount: Int
        var changedChapters: Int
        var examples: [TextCleanupChange]
    }

    func previewTextCleanup(bookId: Int64, rules: [ReaderTextReplacementRule]) async throws -> TextCleanupPreview {
        let active = rules.filter { $0.enabled && !$0.forListenOnly }
        for rule in active { _ = try rule.regex() }
        let chapters = try await chapters(bookId: bookId)
        var matches = 0, changed = 0, examples: [TextCleanupChange] = []
        var revisionParts: [String] = []
        for chapter in chapters {
            let source = try await chapterText(chapter)
            revisionParts.append("\(chapter.chapterIndex):\(ParagraphTranslationRepository.hash(source))")
            let result = try Self.cleanText(source, rules: active)
            matches += result.matches
            if result.text != source {
                changed += 1
                if examples.count < 12 {
                    let before = String(source.prefix(700)), after = String(result.text.prefix(700))
                    examples.append(.init(chapterIndex: chapter.chapterIndex, title: chapter.title, before: before, after: after))
                }
            }
        }
        return .init(revision: ParagraphTranslationRepository.hash(revisionParts.joined(separator: "|")), matchCount: matches, changedChapters: changed, examples: examples)
    }

    func applyTextCleanup(bookId: Int64, rules: [ReaderTextReplacementRule], expectedRevision: String) async throws -> Int {
        let active = rules.filter { $0.enabled && !$0.forListenOnly }
        guard !active.isEmpty else { return 0 }
        for rule in active { _ = try rule.regex() }
        let chapters = try await chapters(bookId: bookId)
        let currentParts = try await chapters.asyncMap { chapter in "\(chapter.chapterIndex):\(ParagraphTranslationRepository.hash(try await self.chapterText(chapter)))" }
        guard ParagraphTranslationRepository.hash(currentParts.joined(separator: "|")) == expectedRevision else {
            throw ReaderEnhancementError.message("正文已变化，请重新预览后再应用")
        }
        var total = 0
        var bodies: [String] = []
        for chapter in chapters {
            let source = try await chapterText(chapter)
            let result = try Self.cleanText(source, rules: active)
            total += result.matches; bodies.append(result.text)
        }
        let ranges = try await textStore.write(bookId: bookId, chapters: bodies.enumerated().map { .init(index: $0.offset, body: $0.element) })
        try await database.transaction { db in
            for range in ranges {
                try db.execute("UPDATE chapters SET charCount=?,textByteOffset=?,textByteLength=? WHERE bookId=? AND chapterIndex=?", [.integer(Int64(range.charCount)),.integer(range.byteOffset),.integer(Int64(range.byteLength)),.integer(bookId),.integer(Int64(range.index))])
            }
            try db.execute("UPDATE books SET lastReadLocator=NULL,lastReadChapterIndex=0,lastReadCharOffset=0,maxReachedChapterIndex=0,maxReachedCharOffset=0,reachedEnd=0 WHERE id=?", [.integer(bookId)])
            try db.execute("DELETE FROM proactive_annotation_jobs WHERE bookId=?", [.integer(bookId)])
            try db.execute("UPDATE audiobook_chapters SET state='STALE' WHERE bookId=?", [.integer(bookId)])
        }
        try? await VectorIndexStore.shared.remove(bookId: bookId)
        return total
    }

    private static func cleanText(_ source: String, rules: [ReaderTextReplacementRule]) throws -> (text: String, matches: Int) {
        var current = source, count = 0
        for rule in rules {
            let regex = try rule.regex(), range = NSRange(location: 0, length: (current as NSString).length)
            count += regex.numberOfMatches(in: current, range: range)
            let replacement = rule.isRegex ? rule.replacement : rule.replacement.replacingOccurrences(of: "$", with: "\\$")
            current = regex.stringByReplacingMatches(in: current, range: range, withTemplate: replacement)
        }
        return (current, count)
    }

    /// Original TXT text used by re-chaptering. New imports preserve book.txt; legacy imports fall back
    /// to a deterministic reconstruction from current chapter titles and canonical bodies.
    func txtSource(bookId: Int64) async throws -> TxtImportSource {
        guard let book = try await book(id: bookId), book.sourceType.uppercased() == "TXT" else {
            throw ImportError.database
        }
        if !book.epubPath.isEmpty, FileManager.default.fileExists(atPath: book.epubPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: book.epubPath)),
           let text = TextImporter.decode(data), !text.isEmpty {
            return .init(title: book.title, text: text)
        }
        let rows = try await chapters(bookId: bookId)
        var output = ""
        for chapter in rows {
            if !output.isEmpty { output += "\n\n" }
            if !chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output += chapter.title + "\n" }
            output += try await chapterText(chapter)
        }
        return .init(title: book.title, text: output)
    }

    /// Rebuilds TXT chapter table + text.mz atomically from a previewed split. Personal records are not
    /// deleted; resume/high-water are reset because chapter coordinates changed.
    func replaceTXTChapters(bookId: Int64, split: TxtSplitResult) async throws {
        guard !split.chapters.isEmpty, let current = try await book(id: bookId), current.sourceType.uppercased() == "TXT" else {
            throw ImportError.noChapters
        }
        let inputs = split.chapters.enumerated().map { ChapterTextInput(index: $0.offset, body: $0.element.content) }
        let ranges = try await textStore.write(bookId: bookId, chapters: inputs)
        try await database.transaction { db in
            try db.execute("DELETE FROM chapters WHERE bookId=?", [.integer(bookId)])
            try db.execute("DELETE FROM book_toc_entries WHERE bookId=?", [.integer(bookId)])
            for (index, item) in split.chapters.enumerated() {
                guard let range = ranges.first(where: { $0.index == index }) else { continue }
                try db.execute("INSERT INTO chapters(bookId,chapterIndex,title,href,charCount,textByteOffset,textByteLength) VALUES(?,?,?,?,?,?,?)", [
                    .integer(bookId), .integer(Int64(index)), .text(item.title), .text("txt:\(index)"), .integer(Int64(range.charCount)), .integer(range.byteOffset), .integer(Int64(range.byteLength))
                ])
                try db.execute("INSERT INTO book_toc_entries(bookId,orderIndex,title,href,depth,parentOrderIndex,chapterIndex,hasChildren) VALUES(?,?,?,?,?,?,?,0)", [
                    .integer(bookId), .integer(Int64(index)), .text(item.title), .text("txt:\(index)"), .integer(0), .null, .integer(Int64(index))
                ])
            }
            try db.execute("UPDATE books SET totalChapters=?,lastReadLocator=NULL,lastReadChapterIndex=0,lastReadCharOffset=0,maxReachedChapterIndex=0,maxReachedCharOffset=0,lastReadAt=0,reachedEnd=0,textVersion=1 WHERE id=?", [
                .integer(Int64(split.chapters.count)), .integer(bookId)
            ])
            try db.execute("DELETE FROM proactive_annotation_jobs WHERE bookId=?", [.integer(bookId)])
            try db.execute("UPDATE audiobook_chapters SET state='STALE' WHERE bookId=?", [.integer(bookId)])
        }
        try? await VectorIndexStore.shared.remove(bookId: bookId)
    }

    func contentRevision(bookId: Int64) async throws -> String { try await textStore.contentRevision(bookId: bookId) }

    enum ImportError: LocalizedError { case noChapters, database
        var errorDescription: String? { self == .noChapters ? "没有可导入的章节" : "导入数据库写入失败" }
    }

    private func persistImportedCover(_ data: Data?, fileExtension: String?, bookId: Int64) throws -> String? {
        guard let data, !data.isEmpty, data.count <= 40 * 1024 * 1024, UIImage(data: data) != nil else { return nil }
        let root = AppPaths.covers
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cleanExtension = (fileExtension ?? "jpg").lowercased().filter { $0.isLetter || $0.isNumber }
        let ext = cleanExtension.isEmpty ? "jpg" : cleanExtension
        let target = root.appendingPathComponent("imported-\(bookId).\(ext)")
        try data.write(to: target, options: .atomic)
        return target.path
    }

    private func copyOriginalSourceIfNeeded(_ url: URL?, type: String, bookId: Int64) throws -> String {
        guard let url else { return "" }
        let kind = type.uppercased()
        guard kind == "EPUB" || kind == "TXT" else { return "" }
        let root = try MoReadDatabase.applicationDirectory().appendingPathComponent("books", isDirectory: true).appendingPathComponent(String(bookId), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent(kind == "EPUB" ? "book.epub" : "book.txt")
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: url, to: target)
        return target.path
    }

    static func nowMillis() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    private static func bool(_ value: SQLValue?) -> Bool { value?.int64 != 0 }
    private static func int(_ row: [String: SQLValue], _ key: String) -> Int { Int(row[key]?.int64 ?? 0) }
    private static func i64(_ row: [String: SQLValue], _ key: String) -> Int64 { row[key]?.int64 ?? 0 }
    private static func text(_ row: [String: SQLValue], _ key: String) -> String { row[key]?.string ?? "" }
    private static func nullableText(_ row: [String: SQLValue], _ key: String) -> String? { row[key]?.string }
    private static func nullableInt(_ row: [String: SQLValue], _ key: String) -> Int64? { row[key]?.int64 }

    private static func book(_ row: [String: SQLValue]) -> Book? {
        guard let id = row["id"]?.int64 else { return nil }
        return Book(id: id, title: text(row,"title"), author: text(row,"author"), coverPath: nullableText(row,"coverPath"), epubPath: text(row,"epubPath"), sourceType: text(row,"sourceType"), importedAt: i64(row,"importedAt"), totalChapters: int(row,"totalChapters"), lastReadLocator: nullableText(row,"lastReadLocator"), lastReadChapterIndex: int(row,"lastReadChapterIndex"), lastReadCharOffset: int(row,"lastReadCharOffset"), maxReachedChapterIndex: int(row,"maxReachedChapterIndex"), maxReachedCharOffset: int(row,"maxReachedCharOffset"), lastReadAt: i64(row,"lastReadAt"), textVersion: int(row,"textVersion"), tags: text(row,"tags"), metadataEdited: bool(row["metadataEdited"]), manualReadState: nullableText(row,"manualReadState"), reachedEnd: bool(row["reachedEnd"]), pinnedAt: i64(row,"pinnedAt"), groupId: nullableInt(row,"groupId"), collectionId: nullableInt(row,"collectionId"), collectionOrder: int(row,"collectionOrder"), removedAt: i64(row,"removedAt"), totalChars: i64(row,"totalChars"), charsBeforeLastChapter: i64(row,"charsBeforeLastChapter"))
    }

    private static func chapter(_ row: [String: SQLValue]) -> Chapter? {
        guard let id = row["id"]?.int64, let bookId = row["bookId"]?.int64 else { return nil }
        return Chapter(id: id, bookId: bookId, chapterIndex: int(row,"chapterIndex"), title: text(row,"title"), href: text(row,"href"), charCount: int(row,"charCount"), textByteOffset: i64(row,"textByteOffset"), textByteLength: int(row,"textByteLength"))
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var output: [T] = []; output.reserveCapacity(count)
        for element in self { output.append(try await transform(element)) }
        return output
    }
}
