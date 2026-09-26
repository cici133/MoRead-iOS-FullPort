import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var int64: Int64? {
        if case let .integer(value) = self { return value }
        return nil
    }
    var string: String? {
        if case let .text(value) = self { return value }
        return nil
    }
    var double: Double? {
        switch self {
        case let .real(value): return value
        case let .integer(value): return Double(value)
        default: return nil
        }
    }
}

enum DatabaseError: LocalizedError {
    case open(String)
    case execute(String, sql: String)
    case prepare(String, sql: String)
    case bind(String)
    case step(String, sql: String)

    var errorDescription: String? {
        switch self {
        case let .open(message): return "无法打开数据库：\(message)"
        case let .execute(message, sql): return "数据库执行失败：\(message)\n\(sql)"
        case let .prepare(message, sql): return "数据库准备失败：\(message)\n\(sql)"
        case let .bind(message): return "数据库参数绑定失败：\(message)"
        case let .step(message, sql): return "数据库读取失败：\(message)\n\(sql)"
        }
    }
}

/// iOS port of MoRead's Room database contract. Table and column names intentionally match
/// Android schema 32 so backup/import tooling can preserve semantic compatibility.
actor MoReadDatabase {
    static let schemaVersion: Int32 = 32
    static let shared = MoReadDatabase()

    private var handle: OpaquePointer?
    private var openedURL: URL?

    deinit { if let handle { sqlite3_close_v2(handle) } }

    func openIfNeeded() throws {
        guard handle == nil else { return }
        let root = try Self.applicationDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("moread.db")
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close_v2(db) }
            throw DatabaseError.open(message)
        }
        handle = db
        openedURL = url
        sqlite3_busy_timeout(db, 10_000)
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try migrateIfNeeded()
    }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
        openedURL = nil
    }

    func databaseURL() throws -> URL {
        try openIfNeeded()
        return openedURL!
    }

    func checkpointForBackup() throws -> URL {
        try openIfNeeded()
        try execute("PRAGMA wal_checkpoint(FULL)")
        guard let openedURL else { throw DatabaseError.open("database path missing") }
        return openedURL
    }

    @discardableResult
    func execute(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64 {
        try openIfNeededWithoutMigrationRecursion()
        guard let handle else { throw DatabaseError.open("database handle missing") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, db: handle)
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError.execute(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        return sqlite3_last_insert_rowid(handle)
    }

    func rows(_ sql: String, _ bindings: [SQLValue] = []) throws -> [[String: SQLValue]] {
        try openIfNeededWithoutMigrationRecursion()
        guard let handle else { throw DatabaseError.open("database handle missing") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, db: handle)
        var result: [[String: SQLValue]] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DatabaseError.step(String(cString: sqlite3_errmsg(handle)), sql: sql)
            }
            var row: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    if let ptr = sqlite3_column_text(statement, index) { row[name] = .text(String(cString: ptr)) }
                    else { row[name] = .null }
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if count > 0, let ptr = sqlite3_column_blob(statement, index) {
                        row[name] = .blob(Data(bytes: ptr, count: count))
                    } else { row[name] = .blob(Data()) }
                default: row[name] = .null
                }
            }
            result.append(row)
        }
        return result
    }

    func scalarInt(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64? {
        try rows(sql, bindings).first?.values.first?.int64
    }

    func transaction<T>(_ body: (isolated MoReadDatabase) throws -> T) throws -> T {
        try openIfNeededWithoutMigrationRecursion()
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body(self)
            try execute("COMMIT")
            return value
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func bind(_ bindings: [SQLValue], to statement: OpaquePointer?, db: OpaquePointer) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(statement, index)
            case let .integer(v): rc = sqlite3_bind_int64(statement, index, v)
            case let .real(v): rc = sqlite3_bind_double(statement, index, v)
            case let .text(v): rc = sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT)
            case let .blob(v):
                rc = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                }
            }
            guard rc == SQLITE_OK else { throw DatabaseError.bind(String(cString: sqlite3_errmsg(db))) }
        }
    }

    private func openIfNeededWithoutMigrationRecursion() throws {
        if handle == nil {
            let root = try Self.applicationDirectory()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("moread.db")
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
                let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
                if let db { sqlite3_close_v2(db) }
                throw DatabaseError.open(message)
            }
            handle = db
            openedURL = url
            sqlite3_busy_timeout(db, 10_000)
        }
    }

    private func migrateIfNeeded() throws {
        let current = Int32(try scalarInt("PRAGMA user_version") ?? 0)
        if current == Self.schemaVersion { return }
        if current == 0 {
            try createSchema32()
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
            return
        }
        // The first iOS build starts from schema 32. Android backup restore keeps its version marker;
        // explicit historical migrations are handled by AndroidBackupImporter before replacing data.
        guard current <= Self.schemaVersion else {
            throw DatabaseError.execute("数据库版本 \(current) 高于本应用支持的版本 \(Self.schemaVersion)", sql: "PRAGMA user_version")
        }
        try createSchema32()
        try execute("PRAGMA user_version = \(Self.schemaVersion)")
    }

    private func createSchema32() throws {
        try execute("PRAGMA foreign_keys = OFF")
        try execute("BEGIN IMMEDIATE")
        do {
            for sql in Self.schema32Statements { try execute(sql) }
            try execute("COMMIT")
            try execute("PRAGMA foreign_keys = ON")
        } catch {
            _ = try? execute("ROLLBACK")
            _ = try? execute("PRAGMA foreign_keys = ON")
            throw error
        }
    }

    static func applicationDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MoRead", isDirectory: true)
    }

    static let schema32Statements: [String] = [
        "CREATE TABLE IF NOT EXISTS proactive_annotation_jobs (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, bookId INTEGER NOT NULL, chapterIndex INTEGER NOT NULL, personaId INTEGER NOT NULL, sourceRevision TEXT NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL, doneParagraphEnds TEXT NOT NULL, failureReason TEXT, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL)",
        "CREATE UNIQUE INDEX IF NOT EXISTS index_proactive_annotation_jobs_bookId_chapterIndex_personaId_sourceRevision ON proactive_annotation_jobs(bookId, chapterIndex, personaId, sourceRevision)",
        "CREATE TABLE IF NOT EXISTS books (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, title TEXT NOT NULL, author TEXT NOT NULL, coverPath TEXT, epubPath TEXT NOT NULL, sourceType TEXT NOT NULL, importedAt INTEGER NOT NULL, totalChapters INTEGER NOT NULL, lastReadLocator TEXT, lastReadChapterIndex INTEGER NOT NULL, lastReadCharOffset INTEGER NOT NULL, maxReachedChapterIndex INTEGER NOT NULL DEFAULT 0, maxReachedCharOffset INTEGER NOT NULL DEFAULT 0, lastReadAt INTEGER NOT NULL, textVersion INTEGER NOT NULL, tags TEXT NOT NULL, metadataEdited INTEGER NOT NULL, manualReadState TEXT DEFAULT NULL, reachedEnd INTEGER NOT NULL DEFAULT 0, pinnedAt INTEGER NOT NULL DEFAULT 0, groupId INTEGER DEFAULT NULL, collectionId INTEGER DEFAULT NULL, collectionOrder INTEGER NOT NULL DEFAULT 0, removedAt INTEGER NOT NULL DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS index_books_collectionId ON books(collectionId)",
        "CREATE TABLE IF NOT EXISTS book_image_styles (bookId INTEGER NOT NULL PRIMARY KEY, specJson TEXT NOT NULL, FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS image_style_templates (id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, specJson TEXT NOT NULL, updatedAt INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS character_looks (id TEXT NOT NULL PRIMARY KEY, bookId INTEGER NOT NULL, characterKey TEXT NOT NULL, sinceChapter INTEGER NOT NULL, specJson TEXT NOT NULL, FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE UNIQUE INDEX IF NOT EXISTS index_character_looks_bookId_characterKey_sinceChapter ON character_looks(bookId, characterKey, sinceChapter)",
        "CREATE TABLE IF NOT EXISTS illustration_queue (id TEXT NOT NULL PRIMARY KEY, bookId INTEGER NOT NULL, chapterIndex INTEGER NOT NULL, sourceText TEXT NOT NULL, recipeJson TEXT NOT NULL, status TEXT NOT NULL, illustrationId INTEGER, error TEXT NOT NULL, createdAt INTEGER NOT NULL, FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_illustration_queue_bookId ON illustration_queue(bookId)",
        "CREATE TABLE IF NOT EXISTS chapters (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, bookId INTEGER NOT NULL, chapterIndex INTEGER NOT NULL, title TEXT NOT NULL, href TEXT NOT NULL, charCount INTEGER NOT NULL, textByteOffset INTEGER NOT NULL, textByteLength INTEGER NOT NULL, FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_chapters_bookId ON chapters(bookId)",
        "CREATE UNIQUE INDEX IF NOT EXISTS index_chapters_bookId_chapterIndex ON chapters(bookId, chapterIndex)",
        "CREATE TABLE IF NOT EXISTS bookmarks (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, bookId INTEGER NOT NULL, locatorJson TEXT NOT NULL, chapterIndex INTEGER NOT NULL, charOffset INTEGER NOT NULL, excerpt TEXT NOT NULL, label TEXT NOT NULL, createdAt INTEGER NOT NULL, FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_bookmarks_bookId ON bookmarks(bookId)",
        "CREATE TABLE IF NOT EXISTS reading_daily (bookId INTEGER NOT NULL, epochDay INTEGER NOT NULL, durationMs INTEGER NOT NULL, lastReadAt INTEGER NOT NULL, PRIMARY KEY(bookId, epochDay), FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_reading_daily_bookId ON reading_daily(bookId)",
        "CREATE TABLE IF NOT EXISTS reading_hourly (bookId INTEGER NOT NULL, epochDay INTEGER NOT NULL, hour INTEGER NOT NULL, durationMs INTEGER NOT NULL, PRIMARY KEY(bookId, epochDay, hour), FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_reading_hourly_bookId ON reading_hourly(bookId)",
        "CREATE INDEX IF NOT EXISTS index_reading_hourly_epochDay ON reading_hourly(epochDay)",
        "CREATE TABLE IF NOT EXISTS ai_providers (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, name TEXT NOT NULL, baseUrl TEXT NOT NULL, apiKeyAlias TEXT NOT NULL, type TEXT NOT NULL, extraJson TEXT NOT NULL, apiFormat TEXT NOT NULL, adapter TEXT NOT NULL DEFAULT 'CUSTOM', createdAt INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS ai_models (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, providerId INTEGER NOT NULL, modelName TEXT NOT NULL, type TEXT NOT NULL DEFAULT 'CHAT', chatApiFormat TEXT NOT NULL DEFAULT '', endpointPath TEXT NOT NULL DEFAULT '', extraJson TEXT NOT NULL DEFAULT '{}', createdAt INTEGER NOT NULL, FOREIGN KEY(providerId) REFERENCES ai_providers(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_ai_models_providerId ON ai_models(providerId)",
        "CREATE TABLE IF NOT EXISTS model_assignments (role TEXT NOT NULL PRIMARY KEY, modelId INTEGER)",
        "CREATE TABLE IF NOT EXISTS conversations (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, bookId INTEGER, personaId INTEGER, title TEXT NOT NULL, type TEXT NOT NULL, bookScopesJson TEXT NOT NULL DEFAULT '[]', parentConversationId INTEGER, branchedFromMessageId INTEGER, memoryConsolidatedThroughMessageId INTEGER NOT NULL DEFAULT 0, rollingSummary TEXT NOT NULL DEFAULT '', summarizedThroughMessageId INTEGER NOT NULL DEFAULT 0, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL DEFAULT 0, FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_conversations_bookId ON conversations(bookId)",
        "CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, conversationId INTEGER NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, toolCallsJson TEXT, toolCallId TEXT, tokenUsage INTEGER, createdAt INTEGER NOT NULL, editedAt INTEGER, attachmentsJson TEXT, reasoningContent TEXT, maskId INTEGER NOT NULL DEFAULT 0, sourceScopeChapterIndex INTEGER NOT NULL DEFAULT -1, sourceScopeCharOffset INTEGER NOT NULL DEFAULT -1, clientRoundId TEXT, sourceBookIdsJson TEXT, inputTokens INTEGER, outputTokens INTEGER, generationTimeMs INTEGER, FOREIGN KEY(conversationId) REFERENCES conversations(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_messages_conversationId ON messages(conversationId)",
        "CREATE TABLE IF NOT EXISTS personas (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, name TEXT NOT NULL, avatarPath TEXT, subtitle TEXT NOT NULL, personality TEXT NOT NULL, speakingStyle TEXT NOT NULL, greeting TEXT NOT NULL, exampleDialogsJson TEXT NOT NULL, isRoleplay INTEGER NOT NULL, enabledToolsJson TEXT NOT NULL, worldBookJson TEXT NOT NULL DEFAULT '[]', worldBookEnabled INTEGER NOT NULL DEFAULT 1, chatModelId INTEGER, userProfile TEXT NOT NULL DEFAULT '', memoryEnabled INTEGER NOT NULL DEFAULT 1, chatAppearanceJson TEXT NOT NULL DEFAULT '{}', voiceId TEXT NOT NULL DEFAULT '', voiceEmotion TEXT NOT NULL DEFAULT '', isBuiltIn INTEGER NOT NULL, createdAt INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS annotations (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, bookId INTEGER NOT NULL, personaId INTEGER, chapterIndex INTEGER NOT NULL, startCharOffset INTEGER NOT NULL, endCharOffset INTEGER NOT NULL, selectedText TEXT NOT NULL, note TEXT NOT NULL, colorTag TEXT NOT NULL, style TEXT NOT NULL DEFAULT 'HIGHLIGHT', mediaJson TEXT NOT NULL DEFAULT '{}', sourceScopeChapterIndex INTEGER, sourceScopeCharOffset INTEGER, textAnchorJson TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL, proactiveJobId INTEGER, FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_annotations_bookId_chapterIndex ON annotations(bookId, chapterIndex)",
        "CREATE INDEX IF NOT EXISTS index_annotations_createdAt_proactiveJobId ON annotations(createdAt, proactiveJobId)",
        "CREATE TABLE IF NOT EXISTS annotation_replies (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, annotationId INTEGER NOT NULL, personaId INTEGER, replyToId INTEGER, contentMarkdown TEXT NOT NULL, mediaJson TEXT NOT NULL DEFAULT '{}', createdAt INTEGER NOT NULL, FOREIGN KEY(annotationId) REFERENCES annotations(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_annotation_replies_annotationId ON annotation_replies(annotationId)",
        "CREATE TABLE IF NOT EXISTS ai_creations (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, bookId INTEGER NOT NULL, type TEXT NOT NULL, chapterIndex INTEGER NOT NULL, startCharOffset INTEGER NOT NULL, endCharOffset INTEGER NOT NULL, directive TEXT NOT NULL, activeVersionId INTEGER, personaId INTEGER, createdAt INTEGER NOT NULL, FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_ai_creations_bookId_chapterIndex ON ai_creations(bookId, chapterIndex)",
        "CREATE TABLE IF NOT EXISTS ai_creation_versions (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, creationId INTEGER NOT NULL, ord INTEGER NOT NULL, directive TEXT NOT NULL, content TEXT NOT NULL, status TEXT NOT NULL, modelName TEXT NOT NULL, createdAt INTEGER NOT NULL, FOREIGN KEY(creationId) REFERENCES ai_creations(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_ai_creation_versions_creationId ON ai_creation_versions(creationId)",
        "CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, bookId INTEGER NOT NULL, personaId INTEGER, title TEXT NOT NULL, contentMarkdown TEXT NOT NULL, kind TEXT NOT NULL, sourceConversationId INTEGER, relatedChapterIndex INTEGER, relatedCharOffset INTEGER, sourceScopeChapterIndex INTEGER, sourceScopeCharOffset INTEGER, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL, FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_notes_bookId ON notes(bookId)",
        "CREATE TABLE IF NOT EXISTS illustrations (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, bookId INTEGER NOT NULL, chapterIndex INTEGER, charOffset INTEGER, sourceText TEXT NOT NULL, prompt TEXT NOT NULL, imagePath TEXT NOT NULL, mediaType TEXT, pixelWidth INTEGER NOT NULL, pixelHeight INTEGER NOT NULL, createdByPersonaId INTEGER, recipeJson TEXT NOT NULL DEFAULT '', castKeys TEXT NOT NULL DEFAULT '[]', textAnchorJson TEXT NOT NULL DEFAULT '', createdAt INTEGER NOT NULL, FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_illustrations_bookId_createdAt ON illustrations(bookId, createdAt)",
        "CREATE TABLE IF NOT EXISTS shelf_groups (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, name TEXT NOT NULL, parentId INTEGER, sortOrder INTEGER NOT NULL, createdAt INTEGER NOT NULL)",
        "CREATE UNIQUE INDEX IF NOT EXISTS index_shelf_groups_parentId_name ON shelf_groups(parentId, name)",
        "CREATE INDEX IF NOT EXISTS index_shelf_groups_parentId ON shelf_groups(parentId)",
        "CREATE TABLE IF NOT EXISTS book_collections (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, name TEXT NOT NULL, createdAt INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS book_tags (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, name TEXT NOT NULL, colorTag TEXT NOT NULL, groupName TEXT NOT NULL, sortOrder INTEGER NOT NULL, createdAt INTEGER NOT NULL)",
        "CREATE UNIQUE INDEX IF NOT EXISTS index_book_tags_name ON book_tags(name)",
        "CREATE TABLE IF NOT EXISTS book_tag_refs (bookId INTEGER NOT NULL, tagId INTEGER NOT NULL, PRIMARY KEY(bookId, tagId), FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE, FOREIGN KEY(tagId) REFERENCES book_tags(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_book_tag_refs_tagId ON book_tag_refs(tagId)",
        "CREATE TABLE IF NOT EXISTS tts_voices (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, voiceId TEXT NOT NULL, displayName TEXT NOT NULL, tags TEXT NOT NULL, gender TEXT NOT NULL, providerHint TEXT NOT NULL, extraJson TEXT NOT NULL, pinned INTEGER NOT NULL, sortOrder INTEGER NOT NULL)",
        "CREATE UNIQUE INDEX IF NOT EXISTS index_tts_voices_providerHint_voiceId ON tts_voices(providerHint, voiceId)",
        "CREATE TABLE IF NOT EXISTS audiobook_roles (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, bookId INTEGER NOT NULL, name TEXT NOT NULL, aliases TEXT NOT NULL, kind TEXT NOT NULL, gender TEXT NOT NULL, engine TEXT NOT NULL, voiceId TEXT NOT NULL, extraJson TEXT NOT NULL, color TEXT NOT NULL, sortOrder INTEGER NOT NULL, source TEXT NOT NULL)",
        "CREATE INDEX IF NOT EXISTS index_audiobook_roles_bookId ON audiobook_roles(bookId)",
        "CREATE TABLE IF NOT EXISTS audiobook_segments (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, bookId INTEGER NOT NULL, chapterIndex INTEGER NOT NULL, startCharOffset INTEGER NOT NULL, endCharOffset INTEGER NOT NULL, roleId INTEGER, emotion TEXT, instruction TEXT, audioPath TEXT, audioMillis INTEGER NOT NULL, revision INTEGER NOT NULL)",
        "CREATE INDEX IF NOT EXISTS index_audiobook_segments_bookId_chapterIndex_startCharOffset ON audiobook_segments(bookId, chapterIndex, startCharOffset)",
        "CREATE TABLE IF NOT EXISTS audiobook_chapters (bookId INTEGER NOT NULL, chapterIndex INTEGER NOT NULL, state TEXT NOT NULL, scriptedAt INTEGER NOT NULL, confirmedAt INTEGER NOT NULL, synthesizedAt INTEGER NOT NULL, segmentCount INTEGER NOT NULL, readySegmentCount INTEGER NOT NULL, totalMillis INTEGER NOT NULL, PRIMARY KEY(bookId, chapterIndex))",
        "CREATE TABLE IF NOT EXISTS book_toc_entries (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, bookId INTEGER NOT NULL, orderIndex INTEGER NOT NULL, title TEXT NOT NULL, href TEXT NOT NULL, depth INTEGER NOT NULL, parentOrderIndex INTEGER, chapterIndex INTEGER, hasChildren INTEGER NOT NULL, FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_book_toc_entries_bookId ON book_toc_entries(bookId)",
        "CREATE UNIQUE INDEX IF NOT EXISTS index_book_toc_entries_bookId_orderIndex ON book_toc_entries(bookId, orderIndex)",
        "CREATE INDEX IF NOT EXISTS index_book_toc_entries_bookId_chapterIndex ON book_toc_entries(bookId, chapterIndex)",
        "CREATE TABLE IF NOT EXISTS chapter_knowledge (bookId INTEGER NOT NULL, chapterIndex INTEGER NOT NULL, sourceRevision TEXT NOT NULL, sourceEnd INTEGER NOT NULL, sourceHash TEXT NOT NULL, modelKey TEXT NOT NULL, modelLabel TEXT NOT NULL, promptVersion INTEGER NOT NULL, contentJson TEXT NOT NULL, createdAt INTEGER NOT NULL, PRIMARY KEY(bookId, chapterIndex), FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_chapter_knowledge_bookId ON chapter_knowledge(bookId)",
        "CREATE TABLE IF NOT EXISTS book_character_guides (bookId INTEGER NOT NULL PRIMARY KEY, generationId TEXT NOT NULL, sourceRevision TEXT NOT NULL, modelKey TEXT NOT NULL, modelLabel TEXT NOT NULL, promptVersion INTEGER NOT NULL, contentJson TEXT NOT NULL, createdAt INTEGER NOT NULL, FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS book_character_parts (bookId INTEGER NOT NULL, chapterIndex INTEGER NOT NULL, start INTEGER NOT NULL, end INTEGER NOT NULL, generationId TEXT NOT NULL, sourceRevision TEXT NOT NULL, sourceHash TEXT NOT NULL, modelKey TEXT NOT NULL, promptVersion INTEGER NOT NULL, contentJson TEXT NOT NULL, createdAt INTEGER NOT NULL, PRIMARY KEY(bookId, chapterIndex, start), FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS index_book_character_parts_bookId ON book_character_parts(bookId)"
    ]
}
