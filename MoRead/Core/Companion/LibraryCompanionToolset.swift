import Foundation

struct LibraryBookScopeSnapshot: Codable, Hashable, Sendable {
    var bookId: Int64
    var title: String
    var maxChapterIndex: Int
    var maxCharOffset: Int
    var textVersion: Int
    var readingScope: ReadingScope { .upto(chapterIndex: maxChapterIndex, charOffset: maxCharOffset) }
}

actor LibraryConversationSources {
    static let maxReadBooks = 4
    static let maxTopicBooks = 32
    private var scopes: [Int64: LibraryBookScopeSnapshot] = [:]
    private var spoilerProtectionEnabled = true
    private var accessed: Set<Int64> = []
    private var associated: Set<Int64> = []

    init(initial: [LibraryBookScopeSnapshot] = [], focused: [Int64] = []) {
        self.scopes = Dictionary(uniqueKeysWithValues: initial.map { ($0.bookId, $0) })
        self.associated = Set(focused)
    }

    func setSpoilerProtection(_ enabled: Bool) { spoilerProtectionEnabled = enabled }

    func authorize(_ bookId: Int64) async throws -> LibraryBookScopeSnapshot {
        guard bookId > 0 else { throw LibraryCompanionError.scope("请先用 find_books 查找有效 book_id") }
        if !accessed.contains(bookId), accessed.count >= Self.maxReadBooks { throw LibraryCompanionError.scope("本轮最多实际查阅 4 本书") }
        if let old = scopes[bookId] {
            guard let current = try await LibraryRepository.shared.book(id: bookId), current.removedAt == 0 else { throw LibraryCompanionError.scope("书籍正文已移除") }
            guard current.textVersion == old.textVersion else { throw LibraryCompanionError.scope("书籍正文已变化，请重新开始本轮查询") }
            let currentScope: ReadingScope = spoilerProtectionEnabled ? .uptoProgress(book: current) : .wholeBook
            guard currentScope.contains(old.readingScope) else { throw LibraryCompanionError.scope("书籍已读范围缩小或防剧透策略已收紧，旧上下文不能继续使用") }
            let refreshed = LibraryBookScopeSnapshot(
                bookId: current.id, title: current.title,
                maxChapterIndex: currentScope.maxChapterIndex, maxCharOffset: currentScope.maxCharOffset,
                textVersion: current.textVersion)
            scopes[bookId] = refreshed
            accessed.insert(bookId); associated.insert(bookId); return refreshed
        }
        guard scopes.count < Self.maxTopicBooks else { throw LibraryCompanionError.scope("本话题涉及书籍较多，请新建话题") }
        guard let book = try await LibraryRepository.shared.book(id: bookId), book.removedAt == 0 else { throw LibraryCompanionError.scope("书籍不存在或正文已移除") }
        let readingScope: ReadingScope = spoilerProtectionEnabled ? .uptoProgress(book: book) : .wholeBook
        let scope = LibraryBookScopeSnapshot(bookId: book.id, title: book.title, maxChapterIndex: readingScope.maxChapterIndex, maxCharOffset: readingScope.maxCharOffset, textVersion: book.textVersion)
        scopes[bookId] = scope; accessed.insert(bookId); associated.insert(bookId); return scope
    }

    func resetTurn(focused: [Int64]) { accessed.removeAll(); associated = Set(focused) }
    func allScopes() -> [LibraryBookScopeSnapshot] { scopes.values.sorted { $0.bookId < $1.bookId } }
    func sourceBookIds() -> [Int64] { associated.sorted() }
}

enum LibraryCompanionToolset {
    static func specs(webEnabled: Bool, spoilerProtected: Bool = true) -> [ToolSpec] {
        let scopeLabel = spoilerProtected ? "已读范围内" : "整本书范围内"
        var values: [ToolSpec] = [
        .init(name:"find_books", description:"按书名、作者、标签或分组查找本地书库。只返回元数据，不读取正文。query 可空。", parameters:["type":"object","properties":["query":["type":"string"],"offset":["type":"integer"]]]),
        .init(name:"list_chapters", description:"列出指定书籍\(scopeLabel)的章节目录。book_id 必须先由 find_books 得到。", parameters:["type":"object","properties":["book_id":["type":"integer"]],"required":["book_id"]]),
        .init(name:"search_book", description:"在指定书籍\(scopeLabel)做词法+向量检索。每轮最多实际查阅 4 本书。", parameters:["type":"object","properties":["book_id":["type":"integer"],"query":["type":"string"]],"required":["book_id","query"]]),
        .init(name:"grep_book", description:"在指定书籍\(scopeLabel)逐字搜索关键词。", parameters:["type":"object","properties":["book_id":["type":"integer"],"query":["type":"string"]],"required":["book_id","query"]]),
        .init(name:"read_book_section", description:"读取指定书籍 1–5 个章节的\(scopeLabel)正文，单次最多返回 6000 UTF-16 字符。", parameters:["type":"object","properties":["book_id":["type":"integer"],"from_chapter":["type":"integer"],"to_chapter":["type":"integer"],"max_chars":["type":"integer"]],"required":["book_id","from_chapter"]]),
        .init(name:"list_annotations", description:"读取指定书籍\(scopeLabel)已有划线和批注。", parameters:["type":"object","properties":["book_id":["type":"integer"]],"required":["book_id"]]),
        .init(name:"list_notes", description:"读取指定书籍在\(scopeLabel)可见的笔记。", parameters:["type":"object","properties":["book_id":["type":"integer"]],"required":["book_id"]]),
        .init(name:"propose_library_organization", description:"为用户准备书架标签/分组整理方案。必须先 find_books 查真实 book_id；这里只生成预览，绝不直接修改书架。每份最多 20 本书，最终必须由用户在界面确认。", parameters:["type":"object","properties":["changes":["type":"array","maxItems":20,"items":["type":"object","properties":["book_id":["type":"integer"],"add_tags":["type":"array","maxItems":8,"items":["type":"string"]],"remove_tags":["type":"array","maxItems":8,"items":["type":"string"]],"group_name":["type":"string"]],"required":["book_id"]]]],"required":["changes"]])
        ]
        if webEnabled {
            values.append(.init(name:"web_search",description:"搜索互联网获取书外知识、近期事实和可引用来源。不要用它查询任何书的未读剧情。",parameters:["type":"object","properties":["query":["type":"string"],"limit":["type":"integer"]],"required":["query"]]))
            values.append(.init(name:"web_scrape",description:"抓取已知网址正文。不要用它绕过任何书籍的已读范围。",parameters:["type":"object","properties":["url":["type":"string"]],"required":["url"]]))
        }
        return values
    }

    static func execute(_ call: ToolCall, sources: LibraryConversationSources) async throws -> String {
        let args = json(call.arguments)
        if call.name == "find_books" { return try await findBooks(args) }
        if call.name == "propose_library_organization" {
            let requests = try LibraryOrganizationPlans.requests(arguments: args)
            let plan = try await LibraryOrganizationCoordinator.shared.preview(requests)
            return try LibraryOrganizationPlans.encode(plan)
        }
        if call.name == "web_search" { let q=(args["query"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines);guard !q.isEmpty else{return failure("INVALID_ARGUMENT")};let rows=try await WebSearchService.shared.search(q,limit:min(8,max(1,number(args["limit"]) ?? 5)));return encode(rows.map{["title":$0.title,"url":$0.url,"snippet":$0.snippet]}) }
        if call.name == "web_scrape" { let u=(args["url"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines);guard !u.isEmpty else{return failure("INVALID_ARGUMENT")};let row=try await WebSearchService.shared.scrape(u);return encode(["title":row.title,"url":row.url,"content":row.content]) }
        guard let bookId = number(args["book_id"]).map(Int64.init) else { return failure("INVALID_BOOK_ID") }
        let snap = try await sources.authorize(bookId)
        let scope = snap.readingScope
        switch call.name {
        case "list_chapters":
            let chapters = try await LibraryRepository.shared.chapters(bookId: bookId).filter { scope.allowsChapter($0.chapterIndex) }
            return encode(["book_id":bookId,"title":snap.title,"chapters":chapters.suffix(120).map { ["chapter":$0.chapterIndex+1,"title":$0.title] }])
        case "search_book":
            let query = args["query"] as? String ?? ""
            let hits = try await RetrievalPipeline.shared.search(bookId: bookId, query: query, scope: scope, limit: 8)
            return sourceHeader(snap) + "\n" + encode(hits.map { ["chapter":$0.chunk.chapterIndex+1,"start":$0.chunk.start,"end":$0.chunk.end,"text":$0.chunk.text,"score":$0.finalScore] })
        case "grep_book":
            let query = args["query"] as? String ?? ""
            let report = try await BookGrep.shared.report(bookId: bookId, query: query, scope: scope, limit: 80)
            return sourceHeader(snap) + "\n" + encode([
                "query": query, "coverage": report.complete ? "complete" : "partial", "count_kind": report.exact ? "exact" : "lower_bound",
                "total_matches": report.totalMatches, "returned_matches": report.returnedMatches,
                "matches": report.matches.map { ["chapter":$0.chapterIndex+1,"start":$0.start,"end":$0.end,"excerpt":$0.excerpt] }
            ])
        case "read_book_section":
            let from = max(1, number(args["from_chapter"]) ?? 1)
            let to = max(from, number(args["to_chapter"]) ?? from)
            guard to - from <= 4 else { return failure("MAX_5_CHAPTERS") }
            let cap = min(6000, max(1000, number(args["max_chars"]) ?? 6000))
            var remaining = cap; var result: [[String: Any]] = []
            for humanIndex in from...to where remaining > 0 {
                let index = humanIndex - 1
                guard scope.allowsChapter(index), let chapter = try await LibraryRepository.shared.chapter(bookId:bookId,index:index) else { continue }
                let text = scope.readableText(chapterIndex:index,text:try await LibraryRepository.shared.chapterText(chapter))
                let ns = text as NSString; let count = min(remaining, ns.length)
                result.append(["chapter":humanIndex,"title":chapter.title,"text":ns.substring(with:NSRange(location:0,length:count))])
                remaining -= count
            }
            return sourceHeader(snap) + "\n" + encode(result)
        case "list_annotations":
            let rows = try await ReaderRecordRepository.shared.annotations(bookId:bookId).filter { scope.allowsChunk(chapterIndex:$0.chapterIndex,startCharOffset:$0.startCharOffset,endCharOffset:$0.endCharOffset) }
            return sourceHeader(snap) + "\n" + encode(rows.prefix(100).map { ["chapter":$0.chapterIndex+1,"quote":$0.selectedText,"note":$0.note] })
        case "list_notes":
            let rows = try await NoteRepository.shared.notes(bookId:bookId).filter { n in guard let c=n.sourceScopeChapterIndex,let o=n.sourceScopeCharOffset else{return true};return scope.allowsPosition(chapterIndex:c,charOffset:o) }
            return sourceHeader(snap) + "\n" + encode(rows.prefix(100).map { ["title":$0.title,"content":$0.contentMarkdown] })
        default: return failure("UNKNOWN_TOOL")
        }
    }

    private static func findBooks(_ args:[String:Any]) async throws -> String {
        let query=(args["query"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        let offset=max(0,number(args["offset"]) ?? 0)
        let books=try await LibraryRepository.shared.listBooks()
        var matches:[Book]=[]
        for book in books {
            let tags = (try? await BookshelfRepository.shared.tags(bookId:book.id)) ?? []
            let hay=([book.title,book.author,book.tags]+tags.map(\.name)).joined(separator:" ").lowercased()
            if query.isEmpty || hay.contains(query) { matches.append(book) }
        }
        let rows=matches.dropFirst(min(offset,matches.count)).prefix(20).map { book in
            ["book_id":book.id,"title":book.title,"author":book.author,"read_chapter":book.maxReachedChapterIndex+1,"read_offset":book.maxReachedCharOffset] as [String:Any]
        }
        var root:[String:Any]=["total":matches.count,"books":rows]
        if offset+20 < matches.count { root["next_offset"]=offset+20 }
        return encode(root)
    }

    private static func sourceHeader(_ scope:LibraryBookScopeSnapshot)->String { "书籍#\(scope.bookId)《\(scope.title)》｜本轮固定已读范围：第 \(scope.maxChapterIndex+1) 章 / UTF-16 \(scope.maxCharOffset)" }
    private static func json(_ raw:String)->[String:Any]{guard let d=raw.data(using:.utf8) else{return [:]};return (try? JSONSerialization.jsonObject(with:d) as? [String:Any]) ?? [:]}
    private static func number(_ value:Any?)->Int?{if let n=value as? NSNumber{return n.intValue};if let s=value as? String{return Int(s)};return nil}
    private static func encode(_ obj:Any)->String{guard JSONSerialization.isValidJSONObject(obj),let d=try? JSONSerialization.data(withJSONObject:obj),let s=String(data:d,encoding:.utf8) else{return "{}"};return s}
    private static func failure(_ code:String)->String{encode(["ok":false,"error_code":code])}
}

enum LibraryCompanionError: LocalizedError { case scope(String); var errorDescription:String?{switch self{case .scope(let s):s}} }
