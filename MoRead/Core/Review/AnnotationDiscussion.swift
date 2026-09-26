import Foundation

struct AnnotationReplyRecord:Identifiable,Sendable{var id:Int64;var annotationId:Int64;var personaId:Int64?;var replyToId:Int64?;var contentMarkdown:String;var mediaJSON:String;var createdAt:Int64}

actor AnnotationDiscussionRepository{
    static let shared=AnnotationDiscussionRepository();private let db=MoReadDatabase.shared
    func replies(annotationId:Int64)async throws->[AnnotationReplyRecord]{try await db.rows("SELECT * FROM annotation_replies WHERE annotationId=? ORDER BY createdAt,id",[.integer(annotationId)]).compactMap(Self.row)}
    @discardableResult func add(annotationId:Int64,personaId:Int64?,replyToId:Int64?=nil,content:String,mediaJSON:String="{}")async throws->Int64{let clean=content.trimmingCharacters(in:.whitespacesAndNewlines);guard !clean.isEmpty else{throw DiscussionError.empty};return try await db.execute("INSERT INTO annotation_replies(annotationId,personaId,replyToId,contentMarkdown,mediaJson,createdAt) VALUES(?,?,?,?,?,?)",[.integer(annotationId),personaId.map(SQLValue.integer) ?? .null,replyToId.map(SQLValue.integer) ?? .null,.text(clean),.text(mediaJSON),.integer(Int64(Date().timeIntervalSince1970*1000))])}
    func delete(id:Int64)async throws{try await db.execute("DELETE FROM annotation_replies WHERE id=?",[.integer(id)])}
    private static func row(_ r:[String:SQLValue])->AnnotationReplyRecord?{guard let id=r["id"]?.int64,let a=r["annotationId"]?.int64 else{return nil};return .init(id:id,annotationId:a,personaId:r["personaId"]?.int64,replyToId:r["replyToId"]?.int64,contentMarkdown:r["contentMarkdown"]?.string ?? "",mediaJSON:r["mediaJson"]?.string ?? "{}",createdAt:r["createdAt"]?.int64 ?? 0)}
}
enum DiscussionError:LocalizedError{case empty;var errorDescription:String?{"回复不能为空"}}

actor AnnotationDiscussionService{
    static let shared=AnnotationDiscussionService()
    func reply(annotation:ReaderAnnotation,book:Book,persona:PersonaRecord,input:String)async throws->String{
        let scope=ReadingScope.uptoProgress(book:book)
        guard scope.allowsChunk(chapterIndex:annotation.chapterIndex,startCharOffset:annotation.startCharOffset,endCharOffset:annotation.endCharOffset) else{throw AIClientError.unsupported("这条批注超出当前已读范围")}
        let thread=try await AnnotationDiscussionRepository.shared.replies(annotationId:annotation.id)
        let personaPrompt=await PersonaRepository.shared.systemPrompt(for:persona,triggerText:input)
        var history:[AIChatMessage]=[.init(role:.system,content:personaPrompt+"\n\n你正在围绕一条已经存在的批注与用户讨论。只能使用当前已读范围；需要核对书中事实时使用只读工具。不要创建新批注、笔记或媒体。"),.init(role:.user,content:"楼主原文：\n\(annotation.selectedText)\n\n楼主批注：\n\(annotation.note)")]
        for row in thread.suffix(24){history.append(.init(role:row.personaId == nil ? .user:.assistant,content:row.contentMarkdown))}
        history.append(.init(role:.user,content:input))
        return try await ReadOnlyBookAgent.shared.run(bookId:book.id,scope:scope,personaId:persona.id,messages:history,maxRounds:5)
    }
}
