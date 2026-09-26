import Foundation

struct ReaderNote:Identifiable,Hashable,Sendable{var id:Int64;var bookId:Int64;var personaId:Int64?;var title:String;var contentMarkdown:String;var kind:String;var relatedChapterIndex:Int?;var relatedCharOffset:Int?;var sourceScopeChapterIndex:Int?;var sourceScopeCharOffset:Int?;var createdAt:Int64;var updatedAt:Int64}

actor NoteRepository {
    static let shared = NoteRepository()
    private let db = MoReadDatabase.shared

    func notes(bookId: Int64) async throws -> [ReaderNote] {
        try await db.rows("SELECT * FROM notes WHERE bookId=? ORDER BY updatedAt DESC,id DESC", [.integer(bookId)]).compactMap(Self.row)
    }

    func allNotes() async throws -> [ReaderNote] {
        try await db.rows("SELECT * FROM notes ORDER BY updatedAt DESC,id DESC").compactMap(Self.row)
    }

    func note(id: Int64) async throws -> ReaderNote? {
        try await db.rows("SELECT * FROM notes WHERE id=? LIMIT 1", [.integer(id)]).first.flatMap(Self.row)
    }

    @discardableResult
    func save(bookId: Int64, personaId: Int64? = nil, title: String, content: String, kind: String = "NOTE", chapterIndex: Int? = nil, charOffset: Int? = nil, scope: ReadingScope? = nil, sourceConversationId: Int64? = nil) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return try await db.execute(
            "INSERT INTO notes(bookId,personaId,title,contentMarkdown,kind,sourceConversationId,relatedChapterIndex,relatedCharOffset,sourceScopeChapterIndex,sourceScopeCharOffset,createdAt,updatedAt) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            [.integer(bookId), personaId.map(SQLValue.integer) ?? .null, .text(title), .text(content), .text(kind), sourceConversationId.map(SQLValue.integer) ?? .null, chapterIndex.map { .integer(Int64($0)) } ?? .null, charOffset.map { .integer(Int64($0)) } ?? .null, scope.map { .integer(Int64($0.maxChapterIndex)) } ?? .null, scope.map { .integer(Int64($0.maxCharOffset)) } ?? .null, .integer(now), .integer(now)]
        )
    }

    func update(id: Int64, title: String, content: String) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await db.execute("UPDATE notes SET title=?,contentMarkdown=?,updatedAt=? WHERE id=?", [.text(title), .text(content), .integer(now), .integer(id)])
    }

    func updateWithPosition(
        id: Int64, title: String, content: String, chapterIndex: Int?, charOffset: Int?, scope: ReadingScope?
    ) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await db.execute(
            "UPDATE notes SET title=?,contentMarkdown=?,relatedChapterIndex=?,relatedCharOffset=?,sourceScopeChapterIndex=?,sourceScopeCharOffset=?,updatedAt=? WHERE id=?",
            [.text(title), .text(content), chapterIndex.map { .integer(Int64($0)) } ?? .null, charOffset.map { .integer(Int64($0)) } ?? .null, scope.map { .integer(Int64($0.maxChapterIndex)) } ?? .null, scope.map { .integer(Int64($0.maxCharOffset)) } ?? .null, .integer(now), .integer(id)]
        )
    }

    func latestByKind(bookId: Int64, personaId: Int64?, kind: String) async throws -> ReaderNote? {
        try await db.rows(
            "SELECT * FROM notes WHERE bookId=? AND personaId IS ? AND kind=? ORDER BY updatedAt DESC,id DESC LIMIT 1",
            [.integer(bookId), personaId.map(SQLValue.integer) ?? .null, .text(kind)]
        ).first.flatMap(Self.row)
    }

    @discardableResult
    func savePlotSummary(
        bookId: Int64, personaId: Int64?, title: String, content: String, chapterIndex: Int?,
        charOffset: Int?, scope: ReadingScope, asNew: Bool = false, requestedNoteId: Int64? = nil,
        sourceConversationId: Int64? = nil
    ) async throws -> Int64 {
        let target: ReaderNote?
        if let requestedNoteId { target = try await note(id: requestedNoteId) }
        else if !asNew { target = try await latestByKind(bookId: bookId, personaId: personaId, kind: "PLOT_SUMMARY") }
        else { target = nil }
        if let target {
            guard target.bookId == bookId, target.personaId == personaId, target.kind == "PLOT_SUMMARY" else {
                throw AIClientError.unsupported("只能更新当前书籍、当前角色自己的剧情梗概")
            }
            try await updateWithPosition(id: target.id, title: title, content: content, chapterIndex: chapterIndex, charOffset: charOffset, scope: scope)
            return target.id
        }
        return try await save(bookId: bookId, personaId: personaId, title: title, content: content, kind: "PLOT_SUMMARY", chapterIndex: chapterIndex, charOffset: charOffset, scope: scope, sourceConversationId: sourceConversationId)
    }

    func delete(id: Int64) async throws {
        try await db.execute("DELETE FROM notes WHERE id=?", [.integer(id)])
    }

    private static func row(_ r: [String: SQLValue]) -> ReaderNote? {
        guard let id = r["id"]?.int64, let bookId = r["bookId"]?.int64 else { return nil }
        let personaId: Int64? = r["personaId"]?.int64
        let title: String = r["title"]?.string ?? ""
        let contentMarkdown: String = r["contentMarkdown"]?.string ?? ""
        let kind: String = r["kind"]?.string ?? ""
        let relatedChapter: Int? = r["relatedChapterIndex"]?.int64.map(Int.init)
        let relatedOffset: Int? = r["relatedCharOffset"]?.int64.map(Int.init)
        let scopeChapter: Int? = r["sourceScopeChapterIndex"]?.int64.map(Int.init)
        let scopeOffset: Int? = r["sourceScopeCharOffset"]?.int64.map(Int.init)
        let createdAt: Int64 = r["createdAt"]?.int64 ?? 0
        let updatedAt: Int64 = r["updatedAt"]?.int64 ?? 0
        return ReaderNote(id: id, bookId: bookId, personaId: personaId, title: title,
                          contentMarkdown: contentMarkdown, kind: kind, relatedChapterIndex: relatedChapter,
                          relatedCharOffset: relatedOffset, sourceScopeChapterIndex: scopeChapter,
                          sourceScopeCharOffset: scopeOffset, createdAt: createdAt, updatedAt: updatedAt)
    }
}

struct CompanionToolset: Sendable {
    let bookId: Int64
    let scope: ReadingScope
    let personaId: Int64?
    let imageEnabled: Bool
    let webEnabled: Bool
    let memoryEnabled: Bool
    let crossBookMemorySearch: Bool
    let maskId: Int64
    let voiceId: String

    init(bookId: Int64, scope: ReadingScope, personaId: Int64? = nil, imageEnabled: Bool = false,
         webEnabled: Bool = false, memoryEnabled: Bool = false, crossBookMemorySearch: Bool = false,
         maskId: Int64 = 0, voiceId: String = "") {
        self.bookId = bookId; self.scope = scope; self.personaId = personaId; self.imageEnabled = imageEnabled
        self.webEnabled = webEnabled; self.memoryEnabled = memoryEnabled; self.crossBookMemorySearch = crossBookMemorySearch
        self.maskId = maskId; self.voiceId = voiceId
    }

    var specs: [ToolSpec] {
        var values: [ToolSpec] = [
            .init(name: "search_book", description: "在当前书已读范围内语义/词法检索相关原文", parameters: ["type":"object","properties":["query":["type":"string"]],"required":["query"]]),
            .init(name: "grep_book", description: "在当前书已读范围内逐字搜索关键词", parameters: ["type":"object","properties":["query":["type":"string"]],"required":["query"]]),
            .init(name: "read_chapter", description: "读取指定章节的已读部分，单次最多 6000 UTF-16 字符", parameters: ["type":"object","properties":["chapter_index":["type":"integer"],"start":["type":"integer"],"length":["type":"integer"]],"required":["chapter_index"]]),
            .init(name: "list_annotations", description: "读取用户在本书已有划线与批注", parameters: ["type":"object","properties":[:]]),
            .init(name: "list_notes", description: "读取本书已有笔记", parameters: ["type":"object","properties":[:]])
        ]
        if webEnabled {
            values.append(.init(name: "web_search", description: "搜索互联网获取书外知识、近期事实和可引用来源。不要用它查询本书未读剧情。", parameters: ["type":"object","properties":["query":["type":"string"],"limit":["type":"integer"]],"required":["query"]]))
            values.append(.init(name: "web_scrape", description: "抓取一个已知 http/https 网址的网页正文；不要用它绕过本书 ReadingScope。", parameters: ["type":"object","properties":["url":["type":"string"]],"required":["url"]]))
        }
        guard personaId != nil else { return values }
        values.append(.init(name: "add_note", description: "用户明确要求保存时写入读书笔记。提供 note_id 时只允许更新当前角色自己在本书的 NOTE；省略则新建。", parameters: ["type":"object","properties":["title":["type":"string"],"content":["type":"string"],"note_id":["type":"integer"],"chapter_index":["type":"integer"],"char_offset":["type":"integer"]],"required":["title","content"]]))
        values.append(.init(name: "add_annotation", description: "在已读原文上添加角色批注。quote 必须逐字来自指定章节且唯一命中；style: HIGHLIGHT/WAVY/UNDERLINE。", parameters: ["type":"object","properties":["chapter_index":["type":"integer"],"quote":["type":"string"],"comment":["type":"string"],"style":["type":"string"]],"required":["chapter_index","quote","comment"]]))
        values.append(.init(name: "save_plot_summary", description: "保存或更新截至当前阅读范围的滚动剧情梗概。默认覆盖当前角色最新一条；只有 as_new=true 才新建。不得写入范围外剧情。", parameters: ["type":"object","properties":["title":["type":"string"],"content":["type":"string"],"note_id":["type":"integer"],"as_new":["type":"boolean"],"from_chapter":["type":"integer"],"to_chapter":["type":"integer"]],"required":["content"]]))
        if memoryEnabled { values.append(.init(name: "recall_memory", description: "检索这个伴读角色与用户之间的长期记忆。只返回稳定摘要；不要把检索结果当作书中原文。", parameters: ["type":"object","properties":["query":["type":"string"]],"required":["query"]])) }
        if imageEnabled { values.append(.init(name: "generate_image", description: "仅当一张插图确实能帮助共读表达时，自主为已读原文场景生成插图。quote 必须逐字来自已读正文，不能引用或暗示未读剧情；不要频繁调用。", parameters: ["type":"object","properties":["chapter_index":["type":"integer"],"quote":["type":"string"],"prompt":["type":"string"]],"required":["chapter_index","quote","prompt"]])) }
        if !voiceId.isEmpty { values.append(.init(name: "synthesize_speech", description: "用户明确希望听角色说某句话时，把给定文字合成为角色语音。不要自动滥用；单次最多 1200 字符。", parameters: ["type":"object","properties":["text":["type":"string"]],"required":["text"]])) }
        return values
    }

    func execute(_ call: ToolCall, sourceConversationId: Int64? = nil) async throws -> String {
        let args = json(call.arguments)
        switch call.name {
        case "search_book":
            let q = args["query"] as? String ?? ""
            let hits = try await RetrievalPipeline.shared.search(bookId: bookId, query: q, scope: scope, limit: 8)
            return encode(hits.map { ["chapter_index":$0.chunk.chapterIndex,"start":$0.chunk.start,"end":$0.chunk.end,"text":$0.chunk.text,"score":$0.finalScore] })
        case "grep_book":
            let q = args["query"] as? String ?? ""
            let report = try await BookGrep.shared.report(bookId: bookId, query: q, scope: scope, limit: 80)
            return encode([
                "query": q, "coverage": report.complete ? "complete" : "partial", "count_kind": report.exact ? "exact" : "lower_bound",
                "total_matches": report.totalMatches, "returned_matches": report.returnedMatches,
                "matches": report.matches.map { ["chapter_index":$0.chapterIndex,"start":$0.start,"end":$0.end,"excerpt":$0.excerpt] }
            ])
        case "read_chapter":
            let index = (args["chapter_index"] as? NSNumber)?.intValue ?? -1
            guard scope.allowsChapter(index), let chapter = try await LibraryRepository.shared.chapter(bookId: bookId, index: index) else { return failure("OUT_OF_SCOPE") }
            let body = scope.readableText(chapterIndex: index, text: try await LibraryRepository.shared.chapterText(chapter)); let ns = body as NSString
            let start = min(max(0, (args["start"] as? NSNumber)?.intValue ?? 0), ns.length)
            let length = min(6000, max(0, (args["length"] as? NSNumber)?.intValue ?? 6000), ns.length - start)
            return encode(["chapter_index":index,"start":start,"end":start+length,"text":ns.substring(with:NSRange(location:start,length:length))])
        case "list_annotations":
            let rows = try await ReaderRecordRepository.shared.annotations(bookId: bookId).filter { scope.allowsChunk(chapterIndex:$0.chapterIndex,startCharOffset:$0.startCharOffset,endCharOffset:$0.endCharOffset) }
            return encode(rows.prefix(100).map { ["chapter_index":$0.chapterIndex,"start":$0.startCharOffset,"end":$0.endCharOffset,"quote":$0.selectedText,"note":$0.note] })
        case "list_notes":
            let rows = try await NoteRepository.shared.notes(bookId: bookId).filter { n in guard let c=n.sourceScopeChapterIndex,let o=n.sourceScopeCharOffset else{return true};return scope.allowsPosition(chapterIndex:c,charOffset:o) }
            return encode(rows.prefix(100).map { ["title":$0.title,"content":$0.contentMarkdown,"chapter_index":$0.relatedChapterIndex.map { $0 as Any } ?? NSNull()] })
        case "add_note":
            guard let personaId else { return failure("CAPABILITY_DISABLED") }
            let title=(args["title"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines), content=(args["content"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            guard !title.isEmpty,!content.isEmpty else{return failure("INVALID_ARGUMENT")}
            let c=(args["chapter_index"] as? NSNumber)?.intValue,o=(args["char_offset"] as? NSNumber)?.intValue
            if let c,let o,!scope.allowsPosition(chapterIndex:c,charOffset:o){return failure("OUT_OF_SCOPE")}
            if let noteId=(args["note_id"] as? NSNumber)?.int64Value {
                guard let old=try await NoteRepository.shared.note(id:noteId) else{return failure("SOURCE_MISSING")}
                guard old.bookId==bookId,old.personaId==personaId,old.kind=="NOTE" else{return failure("WRITE_REJECTED")}
                try await NoteRepository.shared.updateWithPosition(id:noteId,title:String(title.prefix(120)),content:String(content.prefix(50_000)),chapterIndex:c,charOffset:o,scope:scope)
                return encode(["ok":true,"note_id":noteId,"updated":true])
            }
            let id=try await NoteRepository.shared.save(bookId:bookId,personaId:personaId,title:String(title.prefix(120)),content:String(content.prefix(50_000)),kind:"NOTE",chapterIndex:c,charOffset:o,scope:scope,sourceConversationId:sourceConversationId)
            return encode(["ok":true,"note_id":id,"updated":false])
        case "add_annotation":
            guard let personaId else { return failure("CAPABILITY_DISABLED") }
            let chapterIndex=(args["chapter_index"] as? NSNumber)?.intValue ?? -1
            let quote=(args["quote"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            let comment=(args["comment"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            guard chapterIndex >= 0, quote.utf16.count >= 2, !comment.isEmpty, scope.allowsChapter(chapterIndex), let chapter=try await LibraryRepository.shared.chapter(bookId:bookId,index:chapterIndex) else{return failure("OUT_OF_SCOPE")}
            let readable=scope.readableText(chapterIndex:chapterIndex,text:try await LibraryRepository.shared.chapterText(chapter)); let ns=readable as NSString
            let first=ns.range(of:quote); guard first.location != NSNotFound else{return failure("QUOTE_NOT_FOUND")}
            let rest=NSRange(location:first.location+first.length,length:max(0,ns.length-first.location-first.length)); guard ns.range(of:quote,options:[],range:rest).location == NSNotFound else{return failure("QUOTE_AMBIGUOUS")}
            let raw=(args["style"] as? String ?? "HIGHLIGHT").uppercased(); let style=["HIGHLIGHT","UNDERLINE","WAVY"].contains(raw) ? raw : "HIGHLIGHT"
            let colors=["amber","bamboo","indigo","rose"]; let color=colors[Int(personaId.magnitude % UInt64(colors.count))]
            let id=try await ReaderRecordRepository.shared.addAnnotation(bookId:bookId,chapterIndex:chapterIndex,start:first.location,end:first.location+first.length,text:quote,note:comment,colorTag:color,style:style,personaId:personaId,sourceScope:scope)
            return encode(["ok":true,"annotation_id":id,"chapter_index":chapterIndex,"start":first.location,"end":first.location+first.length])
        case "save_plot_summary":
            guard let personaId else { return failure("CAPABILITY_DISABLED") }
            let content=(args["content"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines); guard !content.isEmpty else{return failure("INVALID_ARGUMENT")}
            let currentLast = scope.isWholeBook ? max(0, (try await LibraryRepository.shared.chapters(bookId: bookId).count) - 1) : scope.maxChapterIndex
            let from=max(1,(args["from_chapter"] as? NSNumber)?.intValue ?? 1),to=max(from,(args["to_chapter"] as? NSNumber)?.intValue ?? currentLast+1)
            guard to-1 <= currentLast else{return failure("OUT_OF_SCOPE")}
            let defaultTitle = from == 1 && to == currentLast+1 ? "剧情梗概 · 截至第 \(to) 章" : (from == to ? "剧情梗概 · 第 \(from) 章" : "剧情梗概 · 第 \(from)-\(to) 章")
            let title=(args["title"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).nilIfEmpty ?? defaultTitle
            let requested=(args["note_id"] as? NSNumber)?.int64Value,asNew=(args["as_new"] as? Bool) ?? false
            if let requested, try await NoteRepository.shared.note(id: requested) == nil{return failure("SOURCE_MISSING")}
            let charOffset = (!scope.isWholeBook && to-1 == scope.maxChapterIndex) ? scope.maxCharOffset : nil
            let id=try await NoteRepository.shared.savePlotSummary(bookId:bookId,personaId:personaId,title:String(title.prefix(120)),content:String(content.prefix(50_000)),chapterIndex:to-1,charOffset:charOffset,scope:scope,asNew:asNew,requestedNoteId:requested,sourceConversationId:sourceConversationId)
            return encode(["ok":true,"note_id":id,"as_new":asNew,"from_chapter":from,"to_chapter":to])
        case "recall_memory":
            guard memoryEnabled,let personaId else{return failure("CAPABILITY_DISABLED")};let q=(args["query"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines);guard !q.isEmpty else{return failure("INVALID_ARGUMENT")};let rows=await MemoryRepository.shared.search(query:q,personaId:personaId,bookId:crossBookMemorySearch ? nil:bookId,maskId:maskId,limit:6);return encode(rows.map{["summary":$0.summary,"book_id":$0.bookId.map{$0 as Any} ?? NSNull()]})
        case "web_search":
            guard webEnabled else{return failure("CAPABILITY_DISABLED")};let q=(args["query"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines);guard !q.isEmpty else{return failure("INVALID_ARGUMENT")};let limit=min(8,max(1,(args["limit"] as? NSNumber)?.intValue ?? 5));let rows=try await WebSearchService.shared.search(q,limit:limit);return encode(rows.map{["title":$0.title,"url":$0.url,"snippet":$0.snippet]})
        case "web_scrape":
            guard webEnabled else{return failure("CAPABILITY_DISABLED")};let url=(args["url"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines);guard !url.isEmpty else{return failure("INVALID_ARGUMENT")};let row=try await WebSearchService.shared.scrape(url);return encode(["title":row.title,"url":row.url,"content":row.content])
        case "generate_image":
            guard imageEnabled,let personaId else{return failure("CAPABILITY_DISABLED")};let chapterIndex=(args["chapter_index"] as? NSNumber)?.intValue ?? -1;let quote=(args["quote"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines);let prompt=(args["prompt"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines);guard chapterIndex>=0,quote.utf16.count>=4,!prompt.isEmpty,scope.allowsChapter(chapterIndex),let chapter=try await LibraryRepository.shared.chapter(bookId:bookId,index:chapterIndex) else{return failure("OUT_OF_SCOPE")};let readable=scope.readableText(chapterIndex:chapterIndex,text:try await LibraryRepository.shared.chapterText(chapter));let ns=readable as NSString;let first=ns.range(of:quote);guard first.location != NSNotFound else{return failure("QUOTE_NOT_FOUND")};let rest=NSRange(location:first.location+first.length,length:max(0,ns.length-first.location-first.length));guard ns.range(of:quote,options:[],range:rest).location == NSNotFound else{return failure("QUOTE_AMBIGUOUS")};var recipe=try await ImageConsistencyRepository.shared.plan(bookId:bookId,chapterIndex:chapterIndex,source:quote,useReferences:true);recipe.shot.action=prompt;let generated=try await ImageGenerationService.shared.generate(bookId:bookId,chapterIndex:chapterIndex,charOffset:first.location,sourceText:quote,recipe:recipe,personaId:personaId);return encode(["ok":true,"illustration_id":generated.id,"chapter_index":chapterIndex,"start":first.location,"end":first.location+first.length,"_attachment":["kind":"image","path":generated.imagePath,"title":"伴读插图","text":quote]])
        case "synthesize_speech":
            guard personaId != nil,!voiceId.isEmpty else{return failure("CAPABILITY_DISABLED")};let text=(args["text"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines);guard !text.isEmpty,text.utf16.count <= 1200 else{return failure("INVALID_ARGUMENT")};let url=try await CloudSpeechService.shared.cachedSpeech(text:text,voice:voiceId,bookId:bookId);return encode(["ok":true,"_attachment":["kind":"audio","path":url.path,"title":"角色语音","text":text]])
        default: return failure("UNKNOWN_TOOL")
        }
    }

    private func json(_ s:String)->[String:Any]{guard let d=s.data(using:.utf8) else{return [:]};return (try? JSONSerialization.jsonObject(with:d) as? [String:Any]) ?? [:]}
    private func encode(_ obj:Any)->String{guard JSONSerialization.isValidJSONObject(obj),let d=try? JSONSerialization.data(withJSONObject:obj),let s=String(data:d,encoding:.utf8) else{return "{}"};return s}
    private func failure(_ code:String)->String{encode(["ok":false,"error_code":code])}
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
