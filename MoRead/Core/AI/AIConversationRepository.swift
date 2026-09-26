import Foundation

struct AIConversationRecord: Identifiable, Hashable, Sendable {
    var id:Int64;var bookId:Int64?;var personaId:Int64?;var title:String;var type:String;var bookScopesJSON:String;var parentConversationId:Int64?;var branchedFromMessageId:Int64?;var memoryConsolidatedThroughMessageId:Int64;var rollingSummary:String;var summarizedThroughMessageId:Int64;var createdAt:Int64;var updatedAt:Int64
}
struct AIStoredMessage: Identifiable, Hashable, Sendable {
    var id:Int64;var conversationId:Int64;var role:String;var content:String;var toolCallsJSON:String?;var toolCallId:String?;var tokenUsage:Int64?;var createdAt:Int64;var editedAt:Int64?;var attachmentsJSON:String?;var reasoningContent:String?;var maskId:Int64;var sourceScopeChapterIndex:Int;var sourceScopeCharOffset:Int;var clientRoundId:String?;var sourceBookIdsJSON:String?;var inputTokens:Int64?;var outputTokens:Int64?;var generationTimeMs:Int64?
}

actor AIConversationRepository {
    static let shared=AIConversationRepository();private let db=MoReadDatabase.shared
    func conversations(bookId: Int64?) async throws -> [AIConversationRecord] {
        let rows: [[String: SQLValue]]
        if let bookId {
            rows = try await db.rows("SELECT * FROM conversations WHERE bookId=? ORDER BY updatedAt DESC,createdAt DESC", [.integer(bookId)])
        } else {
            rows = try await db.rows("SELECT * FROM conversations WHERE bookId IS NULL ORDER BY updatedAt DESC,createdAt DESC")
        }
        return rows.compactMap(Self.conversation)
    }
    func conversation(id:Int64)async throws->AIConversationRecord?{try await db.rows("SELECT * FROM conversations WHERE id=?",[.integer(id)]).first.flatMap(Self.conversation)}
    @discardableResult func create(bookId:Int64?,personaId:Int64?=nil,title:String="新会话",type:String="BOOK",parent:Int64?=nil,branchedFrom:Int64?=nil,bookScopesJSON:String?=nil)async throws->Int64{let now=now();let scopes=bookScopesJSON ?? (bookId.map{"[\($0)]"} ?? "[]");return try await db.execute("INSERT INTO conversations(bookId,personaId,title,type,bookScopesJson,parentConversationId,branchedFromMessageId,memoryConsolidatedThroughMessageId,rollingSummary,summarizedThroughMessageId,createdAt,updatedAt) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",[bookId.map(SQLValue.integer) ?? .null,personaId.map(SQLValue.integer) ?? .null,.text(title),.text(type),.text(scopes),parent.map(SQLValue.integer) ?? .null,branchedFrom.map(SQLValue.integer) ?? .null,.integer(0),.text(""),.integer(0),.integer(now),.integer(now)])}
    func messages(conversationId:Int64)async throws->[AIStoredMessage]{try await db.rows("SELECT * FROM messages WHERE conversationId=? ORDER BY id",[.integer(conversationId)]).compactMap(Self.message)}
    @discardableResult func append(conversationId:Int64,role:String,content:String,reasoning:String?=nil,toolCallsJSON:String?=nil,toolCallId:String?=nil,attachmentsJSON:String?=nil,scope:ReadingScope?=nil,clientRoundId:String?=nil,sourceBookIdsJSON:String?=nil,maskId:Int64=0,inputTokens:Int64?=nil,outputTokens:Int64?=nil,generationTimeMs:Int64?=nil)async throws->Int64{let created=now();let id=try await db.execute("INSERT INTO messages(conversationId,role,content,toolCallsJson,toolCallId,tokenUsage,createdAt,editedAt,attachmentsJson,reasoningContent,maskId,sourceScopeChapterIndex,sourceScopeCharOffset,clientRoundId,sourceBookIdsJson,inputTokens,outputTokens,generationTimeMs) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",[.integer(conversationId),.text(role),.text(content),toolCallsJSON.map(SQLValue.text) ?? .null,toolCallId.map(SQLValue.text) ?? .null,(inputTokens ?? 0)+(outputTokens ?? 0)>0 ? .integer((inputTokens ?? 0)+(outputTokens ?? 0)):.null,.integer(created),.null,attachmentsJSON.map(SQLValue.text) ?? .null,reasoning.map(SQLValue.text) ?? .null,.integer(maskId),.integer(Int64(scope?.maxChapterIndex ?? -1)),.integer(Int64(scope?.maxCharOffset ?? -1)),clientRoundId.map(SQLValue.text) ?? .null,sourceBookIdsJSON.map(SQLValue.text) ?? .null,inputTokens.map(SQLValue.integer) ?? .null,outputTokens.map(SQLValue.integer) ?? .null,generationTimeMs.map(SQLValue.integer) ?? .null]);try await db.execute("UPDATE conversations SET updatedAt=? WHERE id=?",[.integer(created),.integer(conversationId)]);return id}
    func updateLibraryContext(conversationId:Int64,bookScopesJSON:String) async throws { try await db.execute("UPDATE conversations SET bookScopesJson=?,updatedAt=? WHERE id=?",[.text(bookScopesJSON),.integer(now()),.integer(conversationId)]) }
    func updateConversationPersona(conversationId:Int64,personaId:Int64?) async throws {
        try await db.execute("UPDATE conversations SET personaId=?,updatedAt=? WHERE id=?",[personaId.map(SQLValue.integer) ?? .null,.integer(now()),.integer(conversationId)])
    }
    func updateMessageSources(messageId:Int64,sourceBookIdsJSON:String) async throws { try await db.execute("UPDATE messages SET sourceBookIdsJson=? WHERE id=?",[.text(sourceBookIdsJSON),.integer(messageId)]) }
    func message(id:Int64) async throws -> AIStoredMessage? { try await db.rows("SELECT * FROM messages WHERE id=?",[.integer(id)]).first.flatMap(Self.message) }
    func message(conversationId:Int64,clientRoundId:String) async throws -> AIStoredMessage? { try await db.rows("SELECT * FROM messages WHERE conversationId=? AND clientRoundId=? ORDER BY id DESC LIMIT 1",[.integer(conversationId),.text(clientRoundId)]).first.flatMap(Self.message) }
    func edit(messageId:Int64,content:String)async throws{try await db.execute("UPDATE messages SET content=?,editedAt=? WHERE id=?",[.text(content),.integer(now()),.integer(messageId)])}
    func updateMessageContent(messageId:Int64,content:String)async throws{try await db.execute("UPDATE messages SET content=?,editedAt=? WHERE id=?",[.text(content),.integer(now()),.integer(messageId)])}

    func editForRegeneration(messageId: Int64, content: String) async throws -> (conversationId: Int64, shouldRegenerate: Bool, user: AIStoredMessage?) {
        let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let target = try await message(id: messageId) else { throw AIClientError.malformed("消息不存在或内容为空") }
        try await edit(messageId: messageId, content: clean)
        if target.role == "user" {
            try await deleteAfter(conversationId: target.conversationId, messageId: target.id)
            try await invalidateHistoryMemory(conversationId: target.conversationId)
            let updated = try await message(id: target.id)
            return (target.conversationId, true, updated)
        }
        return (target.conversationId, false, nil)
    }

    func deleteVisibleMessage(messageId: Int64) async throws {
        guard let target = try await message(id: messageId) else { return }
        if target.role == "user" {
            let all = try await messages(conversationId: target.conversationId)
            let nextUser = all.first { $0.id > target.id && $0.role == "user" }?.id ?? Int64.max
            try await db.execute("DELETE FROM messages WHERE conversationId=? AND id>=? AND id<?", [.integer(target.conversationId), .integer(target.id), .integer(nextUser)])
        } else {
            try await db.execute("DELETE FROM messages WHERE id=?", [.integer(target.id)])
        }
        try await invalidateHistoryMemory(conversationId: target.conversationId)
    }

    func prepareReroll(assistantMessageId: Int64) async throws -> AIStoredMessage {
        guard let target = try await message(id: assistantMessageId), target.role == "assistant" else { throw AIClientError.malformed("只能重新生成 AI 回复") }
        let all = try await messages(conversationId: target.conversationId)
        guard let user = all.last(where: { $0.id < target.id && $0.role == "user" }) else { throw AIClientError.malformed("找不到这条回复对应的用户消息") }
        try await deleteAfter(conversationId: target.conversationId, messageId: user.id)
        try await invalidateHistoryMemory(conversationId: target.conversationId)
        return user
    }

    func prepareRetry(conversationId: Int64) async throws -> AIStoredMessage {
        let all = try await messages(conversationId: conversationId)
        guard let user = all.last(where: { $0.role == "user" }) else { throw AIClientError.malformed("没有需要回复的消息") }
        try await deleteAfter(conversationId: conversationId, messageId: user.id)
        try await invalidateHistoryMemory(conversationId: conversationId)
        return user
    }

    private func invalidateHistoryMemory(conversationId: Int64) async throws {
        try await db.execute("UPDATE conversations SET memoryConsolidatedThroughMessageId=0,rollingSummary='',summarizedThroughMessageId=0,updatedAt=? WHERE id=?", [.integer(now()), .integer(conversationId)])
        try? await MemoryRepository.shared.remove(conversationIds: Set([conversationId]))
    }
    func deleteFrom(conversationId:Int64,messageId:Int64)async throws{try await db.execute("DELETE FROM messages WHERE conversationId=? AND id>=?",[.integer(conversationId),.integer(messageId)])}
    func deleteAfter(conversationId:Int64,messageId:Int64)async throws{try await db.execute("DELETE FROM messages WHERE conversationId=? AND id>?",[.integer(conversationId),.integer(messageId)])}
    func deleteConversation(_ id:Int64)async throws{try await db.execute("DELETE FROM conversations WHERE id=?",[.integer(id)])}
    func renameConversation(_ id:Int64,title:String)async throws{try await db.execute("UPDATE conversations SET title=?,updatedAt=? WHERE id=?",[.text(title),.integer(now()),.integer(id)])}
    func branch(conversationId:Int64,throughMessageId:Int64,title:String="分支")async throws->Int64{guard let parent=try await conversation(id:conversationId) else{throw AIClientError.malformed("会话不存在")};let newId=try await create(bookId:parent.bookId,personaId:parent.personaId,title:title,type:parent.type,parent:conversationId,branchedFrom:throughMessageId,bookScopesJSON:parent.bookScopesJSON);let source=try await db.rows("SELECT * FROM messages WHERE conversationId=? AND id<=? ORDER BY id",[.integer(conversationId),.integer(throughMessageId)]).compactMap(Self.message);for m in source{_ = try await append(conversationId:newId,role:m.role,content:m.content,reasoning:m.reasoningContent,toolCallsJSON:m.toolCallsJSON,toolCallId:m.toolCallId,attachmentsJSON:m.attachmentsJSON,scope:(m.sourceScopeChapterIndex>=0 ? .upto(chapterIndex:m.sourceScopeChapterIndex,charOffset:max(0,m.sourceScopeCharOffset)):nil),clientRoundId:m.clientRoundId,sourceBookIdsJSON:m.sourceBookIdsJSON,maskId:m.maskId,inputTokens:m.inputTokens,outputTokens:m.outputTokens,generationTimeMs:m.generationTimeMs)};return newId}
    private func now()->Int64{Int64(Date().timeIntervalSince1970*1000)}
    private static func conversation(_ r: [String: SQLValue]) -> AIConversationRecord? {
        guard let id = r["id"]?.int64 else { return nil }
        let bookId = r["bookId"]?.int64
        let personaId = r["personaId"]?.int64
        let title = r["title"]?.string ?? ""
        let type = r["type"]?.string ?? "BOOK"
        let scopes = r["bookScopesJson"]?.string ?? "[]"
        let parent = r["parentConversationId"]?.int64
        let branched = r["branchedFromMessageId"]?.int64
        let consolidated = r["memoryConsolidatedThroughMessageId"]?.int64 ?? 0
        let summary = r["rollingSummary"]?.string ?? ""
        let summarizedThrough = r["summarizedThroughMessageId"]?.int64 ?? 0
        let createdAt = r["createdAt"]?.int64 ?? 0
        let updatedAt = r["updatedAt"]?.int64 ?? 0
        return AIConversationRecord(id: id, bookId: bookId, personaId: personaId, title: title, type: type,
                                    bookScopesJSON: scopes, parentConversationId: parent,
                                    branchedFromMessageId: branched,
                                    memoryConsolidatedThroughMessageId: consolidated,
                                    rollingSummary: summary, summarizedThroughMessageId: summarizedThrough,
                                    createdAt: createdAt, updatedAt: updatedAt)
    }

    private static func message(_ r: [String: SQLValue]) -> AIStoredMessage? {
        guard let id = r["id"]?.int64, let cid = r["conversationId"]?.int64 else { return nil }
        let sourceChapter = Int(r["sourceScopeChapterIndex"]?.int64 ?? -1)
        let sourceOffset = Int(r["sourceScopeCharOffset"]?.int64 ?? -1)
        return AIStoredMessage(
            id: id, conversationId: cid,
            role: r["role"]?.string ?? "", content: r["content"]?.string ?? "",
            toolCallsJSON: r["toolCallsJson"]?.string, toolCallId: r["toolCallId"]?.string,
            tokenUsage: r["tokenUsage"]?.int64, createdAt: r["createdAt"]?.int64 ?? 0,
            editedAt: r["editedAt"]?.int64, attachmentsJSON: r["attachmentsJson"]?.string,
            reasoningContent: r["reasoningContent"]?.string, maskId: r["maskId"]?.int64 ?? 0,
            sourceScopeChapterIndex: sourceChapter, sourceScopeCharOffset: sourceOffset,
            clientRoundId: r["clientRoundId"]?.string, sourceBookIdsJSON: r["sourceBookIdsJson"]?.string,
            inputTokens: r["inputTokens"]?.int64, outputTokens: r["outputTokens"]?.int64,
            generationTimeMs: r["generationTimeMs"]?.int64)
    }
}
