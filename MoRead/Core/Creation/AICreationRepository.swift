import Foundation

enum AICreationType: String, Codable, CaseIterable, Sendable { case continueWriting = "CONTINUE", rewrite = "REWRITE" }

struct AICreationRecord: Identifiable, Sendable {
    var id: Int64; var bookId: Int64; var type: AICreationType; var chapterIndex: Int; var start: Int; var end: Int; var directive: String; var activeVersionId: Int64?; var personaId: Int64?; var createdAt: Int64
}
struct AICreationVersionRecord: Identifiable, Sendable {
    var id: Int64; var creationId: Int64; var ord: Int; var directive: String; var content: String; var status: String; var modelName: String; var createdAt: Int64
}

actor AICreationRepository {
    static let shared = AICreationRepository(); private let db = MoReadDatabase.shared
    func creations(bookId:Int64,chapterIndex:Int?=nil) async throws->[AICreationRecord] {
        let rows = if let chapterIndex { try await db.rows("SELECT * FROM ai_creations WHERE bookId=? AND chapterIndex=? ORDER BY createdAt DESC",[.integer(bookId),.integer(Int64(chapterIndex))]) } else { try await db.rows("SELECT * FROM ai_creations WHERE bookId=? ORDER BY chapterIndex,createdAt",[.integer(bookId)]) }
        return rows.compactMap(Self.creation)
    }
    func versions(creationId:Int64) async throws->[AICreationVersionRecord] { try await db.rows("SELECT * FROM ai_creation_versions WHERE creationId=? ORDER BY ord,id",[.integer(creationId)]).compactMap(Self.version) }
    @discardableResult func create(bookId:Int64,type:AICreationType,chapterIndex:Int,start:Int,end:Int,directive:String,personaId:Int64?=nil) async throws->Int64 {
        try await db.execute("INSERT INTO ai_creations(bookId,type,chapterIndex,startCharOffset,endCharOffset,directive,activeVersionId,personaId,createdAt) VALUES(?,?,?,?,?,?,?,?,?)",[.integer(bookId),.text(type.rawValue),.integer(Int64(chapterIndex)),.integer(Int64(start)),.integer(Int64(end)),.text(directive),.null,personaId.map(SQLValue.integer) ?? .null,.integer(now())])
    }
    @discardableResult func addVersion(creationId:Int64,directive:String,content:String,status:String,modelName:String) async throws->Int64 {
        let ord=(try await db.rows("SELECT COALESCE(MAX(ord),-1)+1 AS n FROM ai_creation_versions WHERE creationId=?",[.integer(creationId)]).first?["n"]?.int64 ?? 0)
        let id=try await db.execute("INSERT INTO ai_creation_versions(creationId,ord,directive,content,status,modelName,createdAt) VALUES(?,?,?,?,?,?,?)",[.integer(creationId),.integer(ord),.text(directive),.text(content),.text(status),.text(modelName),.integer(now())])
        try await db.execute("UPDATE ai_creations SET directive=?,activeVersionId=? WHERE id=?",[.text(directive),.integer(id),.integer(creationId)]);return id
    }
    func updateVersion(id:Int64,content:String,status:String) async throws { try await db.execute("UPDATE ai_creation_versions SET content=?,status=? WHERE id=?",[.text(content),.text(status),.integer(id)]) }
    func activate(creationId:Int64,versionId:Int64) async throws { try await db.execute("UPDATE ai_creations SET activeVersionId=? WHERE id=?",[.integer(versionId),.integer(creationId)]) }
    func delete(creationId:Int64) async throws { try await db.execute("DELETE FROM ai_creations WHERE id=?",[.integer(creationId)]) }
    private func now()->Int64{Int64(Date().timeIntervalSince1970*1000)}
    private static func creation(_ r: [String: SQLValue]) -> AICreationRecord? {
        guard let id = r["id"]?.int64, let bookId = r["bookId"]?.int64 else { return nil }
        let type = AICreationType(rawValue: r["type"]?.string ?? "") ?? .rewrite
        let chapterIndex = Int(r["chapterIndex"]?.int64 ?? 0)
        let start = Int(r["startCharOffset"]?.int64 ?? 0)
        let end = Int(r["endCharOffset"]?.int64 ?? 0)
        return .init(id: id, bookId: bookId, type: type, chapterIndex: chapterIndex, start: start, end: end,
                     directive: r["directive"]?.string ?? "", activeVersionId: r["activeVersionId"]?.int64,
                     personaId: r["personaId"]?.int64, createdAt: r["createdAt"]?.int64 ?? 0)
    }
    private static func version(_ r: [String: SQLValue]) -> AICreationVersionRecord? {
        guard let id = r["id"]?.int64, let creationId = r["creationId"]?.int64 else { return nil }
        let ord = Int(r["ord"]?.int64 ?? 0)
        return .init(id: id, creationId: creationId, ord: ord, directive: r["directive"]?.string ?? "",
                     content: r["content"]?.string ?? "", status: r["status"]?.string ?? "DONE",
                     modelName: r["modelName"]?.string ?? "", createdAt: r["createdAt"]?.int64 ?? 0)
    }
}

actor AICreationService {
    static let shared=AICreationService()
    func generate(book:Book,chapter:Chapter,body:String,type:AICreationType,start:Int,end:Int,directive:String,creationId:Int64?=nil) async throws -> Int64 {
        let safeStart=max(0,min(start,body.utf16.count)),safeEnd=max(safeStart,min(end,body.utf16.count))
        let ns=body as NSString
        let selected=safeEnd>safeStart ? ns.substring(with:NSRange(location:safeStart,length:safeEnd-safeStart)) : ""
        let before=ns.substring(with:NSRange(location:max(0,safeStart-5000),length:safeStart-max(0,safeStart-5000)))
        let afterLen=min(3000,max(0,ns.length-safeEnd)),after=ns.substring(with:NSRange(location:safeEnd,length:afterLen))
        let instruction = type == .rewrite ? "改写选中片段，不改变事实、人物关系和叙事视角。只输出改写后的正文。" : "从锚点处续写，保持原文叙事风格、人物设定和当前已读剧情，不预知后文。只输出续写正文。"
        let user="""
        书名：《\(book.title)》\n章节：\(chapter.title)\n用户方向：\(directive.prefix(3000))
        \n【锚点前文】\n\(before)
        \n【选中原文】\n\(selected)
        \n【锚点后文（仅用于保持衔接；续写时不得把它当作要复述的未来正文）】\n\(after)
        """
        let resolved=try await AIClientFactory.forRole(.chat)
        let output=try await resolved.client.chat(messages:[.init(role:.system,content:instruction),.init(role:.user,content:user)],options:resolved.options)
        guard !output.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw AIClientError.empty}
        let cid: Int64
        if let creationId {
            cid = creationId
        } else {
            cid = try await AICreationRepository.shared.create(bookId: book.id, type: type, chapterIndex: chapter.chapterIndex, start: safeStart, end: safeEnd, directive: directive)
        }
        _ = try await AICreationRepository.shared.addVersion(creationId: cid, directive: directive, content: output, status: "DONE", modelName: resolved.modelName)
        return cid
    }
    func continueVersion(creation:AICreationRecord,version:AICreationVersionRecord,book:Book,chapter:Chapter,directive:String) async throws {
        let resolved=try await AIClientFactory.forRole(.chat)
        let text=try await resolved.client.chat(messages:[.init(role:.system,content:"继续当前创作版本。保持已有内容的风格和逻辑，只输出新增正文，不重复前文。"),.init(role:.user,content:"书名：《\(book.title)》\n章节：\(chapter.title)\n方向：\(directive)\n已有创作：\n\(version.content.suffix(12000))")],options:resolved.options)
        try await AICreationRepository.shared.updateVersion(id:version.id,content:version.content+text,status:"DONE")
    }
}
