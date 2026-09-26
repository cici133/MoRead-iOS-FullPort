import Foundation

struct IllustrationQueueItem:Identifiable,Hashable,Sendable{var id:String;var bookId:Int64;var chapterIndex:Int;var sourceText:String;var recipeJSON:String;var status:String;var illustrationId:Int64?;var error:String;var createdAt:Int64}
actor IllustrationQueue {
    static let shared=IllustrationQueue();private let db=MoReadDatabase.shared;private var running:Set<Int64>=[];private var paused:Set<Int64>=[]
    func prepare(bookId:Int64,first:Int,last:Int,useReferences:Bool=true)async throws->[IllustrationQueueItem]{
        guard first>=0,last>=first,last-first<100 else{throw ImageGenerationError.unsupported("每次请选择 1–100 章")}
        guard let book=try await LibraryRepository.shared.book(id:bookId),book.removedAt==0 else{throw ImageGenerationError.unsupported("书籍正文已移除")}
        let scope=ReadingScope.uptoProgress(book:book);guard last<=scope.maxChapterIndex else{throw ImageGenerationError.unsupported("只能为已读章节生成插图")}
        let chapters=try await LibraryRepository.shared.chapters(bookId:bookId);var out:[IllustrationQueueItem]=[]
        for c in chapters where c.chapterIndex>=first && c.chapterIndex<=last{
            try Task.checkCancellation()
            let text=String(scope.readableText(chapterIndex:c.chapterIndex,text:try await LibraryRepository.shared.chapterText(c)).prefix(12_000))
            if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{continue}
            let recipe=try await ImageConsistencyRepository.shared.plan(bookId:bookId,chapterIndex:c.chapterIndex,source:text,useReferences:useReferences)
            out.append(.init(id:UUID().uuidString,bookId:bookId,chapterIndex:c.chapterIndex,sourceText:text,recipeJSON:try ImageRecipeLogic.encode(recipe),status:"pending",illustrationId:nil,error:"",createdAt:Int64(Date().timeIntervalSince1970*1000)))
        }
        return out
    }
    func enqueue(_ rows:[IllustrationQueueItem])async throws{for r in rows{try await db.execute("INSERT OR REPLACE INTO illustration_queue(id,bookId,chapterIndex,sourceText,recipeJson,status,illustrationId,error,createdAt) VALUES(?,?,?,?,?,?,?,?,?)",[.text(r.id),.integer(r.bookId),.integer(Int64(r.chapterIndex)),.text(r.sourceText),.text(r.recipeJSON),.text(r.status),r.illustrationId.map(SQLValue.integer) ?? .null,.text(r.error),.integer(r.createdAt)])}}
    func items(bookId:Int64)async throws->[IllustrationQueueItem]{try await db.rows("SELECT * FROM illustration_queue WHERE bookId=? ORDER BY createdAt,id",[.integer(bookId)]).compactMap(Self.row)}
    func pause(bookId:Int64){paused.insert(bookId)}
    func start(bookId:Int64)async{guard !running.contains(bookId) else{return};running.insert(bookId);paused.remove(bookId);defer{running.remove(bookId);paused.remove(bookId)};guard let rows=try? await items(bookId:bookId) else{return};for row in rows where row.status=="pending"{if paused.contains(bookId){break};do{guard let book=try await LibraryRepository.shared.book(id:bookId),book.removedAt==0,row.chapterIndex<=book.maxReachedChapterIndex,let recipe=ImageRecipeLogic.decode(row.recipeJSON) else{break};try await db.execute("UPDATE illustration_queue SET status='running',error='' WHERE id=?",[.text(row.id)]);let generated=try await ImageGenerationService.shared.generate(bookId:bookId,chapterIndex:row.chapterIndex,charOffset:nil,sourceText:row.sourceText,recipe:recipe,persist:false);let iid=try await ImageGenerationService.shared.insert(generated);try await db.execute("UPDATE illustration_queue SET status='done',illustrationId=?,error='' WHERE id=?",[.integer(iid),.text(row.id)])}catch{try? await db.execute("UPDATE illustration_queue SET status='failed',error=? WHERE id=?",[.text(String(error.localizedDescription.prefix(500))),.text(row.id)])}}}
    func retry(id:String)async throws{try await db.execute("UPDATE illustration_queue SET status='pending',error='' WHERE id=?",[.text(id)])}
    private static func row(_ r: [String: SQLValue]) -> IllustrationQueueItem? {
        guard let id = r["id"]?.string, let bookId = r["bookId"]?.int64 else { return nil }
        let chapterIndex = Int(r["chapterIndex"]?.int64 ?? 0)
        return .init(id: id, bookId: bookId, chapterIndex: chapterIndex,
                     sourceText: r["sourceText"]?.string ?? "", recipeJSON: r["recipeJson"]?.string ?? "",
                     status: r["status"]?.string ?? "pending", illustrationId: r["illustrationId"]?.int64,
                     error: r["error"]?.string ?? "", createdAt: r["createdAt"]?.int64 ?? 0)
    }
}
