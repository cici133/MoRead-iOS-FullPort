import Foundation

struct StorageCategory: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let bytes: Int64
}

struct BookStorageUsage: Identifiable, Sendable {
    let id: Int64
    let title: String
    let removed: Bool
    let contentBytes: Int64
    let speechBytes: Int64
    let illustrationBytes: Int64
    let attachmentBytes: Int64
    var totalBytes: Int64 { contentBytes + speechBytes + illustrationBytes + attachmentBytes }
}

struct StorageSnapshot: Sendable {
    var categories: [StorageCategory]
    var books: [BookStorageUsage]
    var totalBytes: Int64 { categories.reduce(0) { $0 + $1.bytes } }
}

actor StorageRepository {
    static let shared = StorageRepository()
    private let fm = FileManager.default
    private let db = MoReadDatabase.shared

    func snapshot() async throws -> StorageSnapshot {
        let books = try await LibraryRepository.shared.listBooks(includeRemoved: true)
        let illustrationRows = try await db.rows("SELECT bookId,imagePath FROM illustrations")
        let illustrations = Dictionary(grouping: illustrationRows, by: { $0["bookId"]?.int64 ?? -1 })
        let attachmentRows = try await db.rows("""
            SELECT c.bookId,m.attachmentsJson FROM messages m
            JOIN conversations c ON c.id=m.conversationId
            WHERE c.bookId IS NOT NULL AND m.attachmentsJson IS NOT NULL
            """)
        let attachments = Dictionary(grouping: attachmentRows, by: { $0["bookId"]?.int64 ?? -1 })
        let perBook = books.map { book in
            let content = [
                AppPaths.booksRoot.appendingPathComponent(String(book.id), isDirectory: true),
                AppPaths.bookTextRoot.appendingPathComponent(String(book.id), isDirectory: true),
                AppPaths.bookMediaRoot.appendingPathComponent(String(book.id), isDirectory: true),
                AppPaths.bookLayoutRoot.appendingPathComponent(String(book.id), isDirectory: true),
                AppPaths.bookIndexRoot.appendingPathComponent("\(book.id).plist")
            ].reduce(Int64(0)) { $0 + size($1) }
            let speech = size(AppPaths.speechCache(bookId: book.id))
            let images = illustrations[book.id, default: []].reduce(Int64(0)) { sum, row in
                sum + (row["imagePath"]?.string.map { size(URL(fileURLWithPath: $0)) } ?? 0)
            }
            let mediaPaths = attachments[book.id, default: []].flatMap { row in
                row["attachmentsJson"]?.string.map(Self.attachmentPaths) ?? []
            }
            let attachmentBytes = Set(mediaPaths).reduce(Int64(0)) { $0 + size(URL(fileURLWithPath: $1)) }
            return BookStorageUsage(id: book.id, title: book.title, removed: book.removedAt != 0, contentBytes: content, speechBytes: speech, illustrationBytes: images, attachmentBytes: attachmentBytes)
        }
        let categories = [
            StorageCategory(name: "数据库", bytes: databaseBytes()),
            StorageCategory(name: "书籍与正文", bytes: size(AppPaths.booksRoot) + size(AppPaths.bookTextRoot) + size(AppPaths.bookMediaRoot) + size(AppPaths.bookLayoutRoot)),
            StorageCategory(name: "向量索引", bytes: size(AppPaths.bookIndexRoot)),
            StorageCategory(name: "语音缓存", bytes: size(AppPaths.speechCache)),
            StorageCategory(name: "插图", bytes: size(AppPaths.illustrations)),
            StorageCategory(name: "附件", bytes: size(AppPaths.attachments)),
            StorageCategory(name: "图片/Vibe", bytes: size(AppPaths.imageLibrary) + size(AppPaths.imageVibes) + size(AppPaths.covers) + size(AppPaths.avatars)),
            StorageCategory(name: "阅读自定义资源", bytes: size(AppPaths.readerCustom)),
            StorageCategory(name: "临时导出", bytes: size(AppPaths.exports)),
            StorageCategory(name: "备份", bytes: size(AppPaths.backups))
        ]
        return StorageSnapshot(categories: categories, books: perBook.sorted { $0.totalBytes > $1.totalBytes })
    }

    func clearSpeech(bookId: Int64? = nil) throws {
        let url = bookId.map { AppPaths.speechCache(bookId: $0) } ?? AppPaths.speechCache
        try? fm.removeItem(at: url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func clearIndexes(bookId: Int64? = nil) async throws {
        if let bookId { try await VectorIndexStore.shared.remove(bookId: bookId) }
        else { try await VectorIndexStore.shared.removeAll() }
    }

    func clearExports() throws {
        try? fm.removeItem(at: AppPaths.exports)
        try fm.createDirectory(at: AppPaths.exports, withIntermediateDirectories: true)
    }

    /// Deletes only files with no live database/settings reference. Shared image-library assets are never touched.
    func cleanupOrphans() async throws -> Int64 {
        var reclaimed: Int64 = 0
        let validIllustrations = Set(try await db.rows("SELECT imagePath FROM illustrations").compactMap { $0["imagePath"]?.string })
        if let e = fm.enumerator(at: AppPaths.illustrations, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let file as URL in e where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                if !validIllustrations.contains(file.path) { reclaimed += size(file); try? fm.removeItem(at: file) }
            }
        }
        let bookIds = Set(try await LibraryRepository.shared.listBooks(includeRemoved: true).map(\.id))
        if let children = try? fm.contentsOfDirectory(at: AppPaths.speechCache, includingPropertiesForKeys: nil) {
            for child in children where child.hasDirectoryPath {
                if child.lastPathComponent == "global" { continue }
                if let id = Int64(child.lastPathComponent), !bookIds.contains(id) { reclaimed += size(child); try? fm.removeItem(at: child) }
            }
        }
        return reclaimed
    }

    func removeBodyKeepingRecords(bookId: Int64) async throws { try await LibraryRepository.shared.softRemove(bookId: bookId) }
    func permanentlyDelete(bookId: Int64) async throws { try await LibraryRepository.shared.permanentlyDelete(bookId: bookId) }

    private func databaseBytes() -> Int64 {
        guard let url = try? MoReadDatabase.applicationDirectory().appendingPathComponent("moread.db") else { return 0 }
        return size(url) + size(URL(fileURLWithPath: url.path + "-wal")) + size(URL(fileURLWithPath: url.path + "-shm"))
    }

    private func size(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0 }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    private static func attachmentPaths(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8), let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { $0["path"] as? String }
    }
}
