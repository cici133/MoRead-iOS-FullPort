import Foundation

struct ReaderAnnotation: Identifiable, Hashable, Sendable {
    var id: Int64
    var bookId: Int64
    var personaId: Int64?
    var chapterIndex: Int
    var startCharOffset: Int
    var endCharOffset: Int
    var selectedText: String
    var note: String
    var colorTag: String
    var style: String
    var mediaJSON: String
    var sourceScopeChapterIndex: Int?
    var sourceScopeCharOffset: Int?
    var textAnchorJSON: String
    var createdAt: Int64
    var proactiveJobId: Int64?
}

struct ReaderBookmark: Identifiable, Hashable, Sendable {
    var id: Int64
    var bookId: Int64
    var locatorJSON: String
    var chapterIndex: Int
    var charOffset: Int
    var excerpt: String
    var label: String
    var createdAt: Int64
}

actor ReaderRecordRepository {
    static let shared = ReaderRecordRepository()
    private let db = MoReadDatabase.shared

    func annotations(bookId:Int64,chapterIndex:Int?=nil) async throws->[ReaderAnnotation]{
        let rows = if let chapterIndex { try await db.rows("SELECT * FROM annotations WHERE bookId=? AND chapterIndex=? ORDER BY startCharOffset,createdAt",[.integer(bookId),.integer(Int64(chapterIndex))]) } else { try await db.rows("SELECT * FROM annotations WHERE bookId=? ORDER BY chapterIndex,startCharOffset,createdAt",[.integer(bookId)]) }
        return rows.compactMap(Self.annotation)
    }
    func allAnnotations() async throws -> [ReaderAnnotation] {
        try await db.rows("SELECT * FROM annotations ORDER BY createdAt DESC,id DESC").compactMap(Self.annotation)
    }
    @discardableResult func addAnnotation(bookId:Int64,chapterIndex:Int,start:Int,end:Int,text:String,note:String="",colorTag:String="yellow",style:String="HIGHLIGHT",personaId:Int64?=nil,sourceScope:ReadingScope?=nil,textAnchorJSON:String="",proactiveJobId:Int64?=nil,mediaJSON:String="{}") async throws->Int64{
        try await db.execute("INSERT INTO annotations(bookId,personaId,chapterIndex,startCharOffset,endCharOffset,selectedText,note,colorTag,style,mediaJson,sourceScopeChapterIndex,sourceScopeCharOffset,textAnchorJson,createdAt,proactiveJobId) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",[
            .integer(bookId),personaId.map(SQLValue.integer) ?? .null,.integer(Int64(chapterIndex)),.integer(Int64(start)),.integer(Int64(end)),.text(text),.text(note),.text(colorTag),.text(style),.text(mediaJSON),sourceScope.map{.integer(Int64($0.maxChapterIndex))} ?? .null,sourceScope.map{.integer(Int64($0.maxCharOffset))} ?? .null,.text(textAnchorJSON),.integer(now()),proactiveJobId.map(SQLValue.integer) ?? .null])
    }
    func updateAnnotation(id:Int64,note:String,colorTag:String,style:String) async throws{try await db.execute("UPDATE annotations SET note=?,colorTag=?,style=? WHERE id=?",[.text(note),.text(colorTag),.text(style),.integer(id)])}
    func deleteAnnotation(id:Int64) async throws{try await db.execute("DELETE FROM annotations WHERE id=?",[.integer(id)])}

    func bookmarks(bookId:Int64) async throws->[ReaderBookmark]{try await db.rows("SELECT * FROM bookmarks WHERE bookId=? ORDER BY chapterIndex,charOffset",[.integer(bookId)]).compactMap(Self.bookmark)}
    func bookmark(bookId:Int64,chapterIndex:Int,charOffset:Int) async throws->ReaderBookmark?{try await db.rows("SELECT * FROM bookmarks WHERE bookId=? AND chapterIndex=? AND charOffset=? LIMIT 1",[.integer(bookId),.integer(Int64(chapterIndex)),.integer(Int64(charOffset))]).first.flatMap(Self.bookmark)}
    @discardableResult func addBookmark(bookId:Int64,chapterIndex:Int,charOffset:Int,excerpt:String,label:String="") async throws->Int64{
        let locator="{\"chapterIndex\":\(chapterIndex),\"charOffset\":\(charOffset)}"
        return try await db.execute("INSERT INTO bookmarks(bookId,locatorJson,chapterIndex,charOffset,excerpt,label,createdAt) VALUES(?,?,?,?,?,?,?)",[.integer(bookId),.text(locator),.integer(Int64(chapterIndex)),.integer(Int64(charOffset)),.text(excerpt),.text(label),.integer(now())])
    }
    func deleteBookmark(id:Int64) async throws{try await db.execute("DELETE FROM bookmarks WHERE id=?",[.integer(id)])}

    private func now()->Int64{Int64((Date().timeIntervalSince1970*1000).rounded())}
    private static func annotation(_ r: [String: SQLValue]) -> ReaderAnnotation? {
        guard let id = r["id"]?.int64, let bookId = r["bookId"]?.int64 else { return nil }
        let chapterIndex = Int(r["chapterIndex"]?.int64 ?? 0)
        let start = Int(r["startCharOffset"]?.int64 ?? 0)
        let end = Int(r["endCharOffset"]?.int64 ?? 0)
        let scopeChapter = r["sourceScopeChapterIndex"]?.int64.map(Int.init)
        let scopeOffset = r["sourceScopeCharOffset"]?.int64.map(Int.init)
        let personaId: Int64? = r["personaId"]?.int64
        let selectedText: String = r["selectedText"]?.string ?? ""
        let note: String = r["note"]?.string ?? ""
        let colorTag: String = r["colorTag"]?.string ?? ""
        let style: String = r["style"]?.string ?? "HIGHLIGHT"
        let mediaJSON: String = r["mediaJson"]?.string ?? "{}"
        let textAnchorJSON: String = r["textAnchorJson"]?.string ?? ""
        let createdAt: Int64 = r["createdAt"]?.int64 ?? 0
        let proactiveJobId: Int64? = r["proactiveJobId"]?.int64
        return ReaderAnnotation(id: id, bookId: bookId, personaId: personaId, chapterIndex: chapterIndex,
                                startCharOffset: start, endCharOffset: end, selectedText: selectedText,
                                note: note, colorTag: colorTag, style: style, mediaJSON: mediaJSON,
                                sourceScopeChapterIndex: scopeChapter, sourceScopeCharOffset: scopeOffset,
                                textAnchorJSON: textAnchorJSON, createdAt: createdAt, proactiveJobId: proactiveJobId)
    }
    private static func bookmark(_ r: [String: SQLValue]) -> ReaderBookmark? {
        guard let id = r["id"]?.int64, let bookId = r["bookId"]?.int64 else { return nil }
        let chapterIndex = Int(r["chapterIndex"]?.int64 ?? 0)
        let offset = Int(r["charOffset"]?.int64 ?? 0)
        return .init(id: id, bookId: bookId, locatorJSON: r["locatorJson"]?.string ?? "",
                     chapterIndex: chapterIndex, charOffset: offset, excerpt: r["excerpt"]?.string ?? "",
                     label: r["label"]?.string ?? "", createdAt: r["createdAt"]?.int64 ?? 0)
    }
}
