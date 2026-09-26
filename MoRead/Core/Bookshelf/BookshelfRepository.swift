import Foundation

enum BookReadState: String, CaseIterable, Sendable { case unread="UNREAD", reading="READING", finished="FINISHED", shelved="SHELVED"; var label:String{switch self{case .unread:"未读";case .reading:"在读";case .finished:"已读完";case .shelved:"搁置"}} }
struct ShelfGroup:Identifiable,Hashable,Sendable{var id:Int64;var name:String;var parentId:Int64?;var sortOrder:Int;var createdAt:Int64}
struct BookCollection:Identifiable,Hashable,Sendable{var id:Int64;var name:String;var createdAt:Int64}
struct BookTag:Identifiable,Hashable,Sendable{var id:Int64;var name:String;var colorTag:String;var groupName:String;var sortOrder:Int;var createdAt:Int64}
struct BookTagRef:Hashable,Sendable{var bookId:Int64;var tagId:Int64}

actor BookshelfRepository {
    static let shared=BookshelfRepository();private let db=MoReadDatabase.shared
    func readState(_ book:Book)->BookReadState{if let raw=book.manualReadState,let s=BookReadState(rawValue:raw){return s};if book.lastReadAt==0{return .unread};if book.reachedEnd{return .finished};return .reading}
    func setReadState(bookId:Int64,state:BookReadState?)async throws{try await db.execute("UPDATE books SET manualReadState=? WHERE id=?",[state.map{.text($0.rawValue)} ?? .null,.integer(bookId)])}
    func setPinned(bookId:Int64,pinned:Bool)async throws{try await db.execute("UPDATE books SET pinnedAt=? WHERE id=?",[.integer(pinned ? now():0),.integer(bookId)])}
    func setGroup(bookId:Int64,groupId:Int64?)async throws{try await db.execute("UPDATE books SET groupId=? WHERE id=?",[groupId.map(SQLValue.integer) ?? .null,.integer(bookId)])}
    func setCollection(bookId:Int64,collectionId:Int64?,order:Int=0)async throws{try await db.execute("UPDATE books SET collectionId=?,collectionOrder=? WHERE id=?",[collectionId.map(SQLValue.integer) ?? .null,.integer(Int64(order)),.integer(bookId)])}
    func reorderCollection(bookIds:[Int64],collectionId:Int64?)async throws{try await db.transaction{db in for (i,id) in bookIds.enumerated(){try db.execute("UPDATE books SET collectionId=?,collectionOrder=? WHERE id=?",[collectionId.map(SQLValue.integer) ?? .null,.integer(Int64(i)),.integer(id)])}}}
    func groups()async throws->[ShelfGroup]{try await db.rows("SELECT * FROM shelf_groups ORDER BY parentId,sortOrder,createdAt").compactMap{r in guard let id=r["id"]?.int64 else{return nil};return .init(id:id,name:r["name"]?.string ?? "",parentId:r["parentId"]?.int64,sortOrder:Int(r["sortOrder"]?.int64 ?? 0),createdAt:r["createdAt"]?.int64 ?? 0)}}
    @discardableResult func createGroup(name:String,parentId:Int64?=nil)async throws->Int64{let order=try await db.scalarInt("SELECT COALESCE(MAX(sortOrder),-1)+1 FROM shelf_groups WHERE parentId IS ?",[parentId.map(SQLValue.integer) ?? .null]) ?? 0;return try await db.execute("INSERT INTO shelf_groups(name,parentId,sortOrder,createdAt) VALUES(?,?,?,?)",[.text(name.trimmingCharacters(in:.whitespacesAndNewlines)),parentId.map(SQLValue.integer) ?? .null,.integer(order),.integer(now())])}
    func renameGroup(_ id:Int64,name:String)async throws{try await db.execute("UPDATE shelf_groups SET name=? WHERE id=?",[.text(name),.integer(id)])}
    func deleteGroup(_ id:Int64)async throws{try await db.transaction{db in try db.execute("UPDATE books SET groupId=NULL WHERE groupId=?",[.integer(id)]);try db.execute("UPDATE shelf_groups SET parentId=NULL WHERE parentId=?",[.integer(id)]);try db.execute("DELETE FROM shelf_groups WHERE id=?",[.integer(id)])}}
    func collections()async throws->[BookCollection]{try await db.rows("SELECT * FROM book_collections ORDER BY createdAt").compactMap{r in guard let id=r["id"]?.int64 else{return nil};return .init(id:id,name:r["name"]?.string ?? "",createdAt:r["createdAt"]?.int64 ?? 0)}}
    @discardableResult func createCollection(name:String)async throws->Int64{try await db.execute("INSERT INTO book_collections(name,createdAt) VALUES(?,?)",[.text(name),.integer(now())])}
    func renameCollection(_ id:Int64,name:String)async throws{try await db.execute("UPDATE book_collections SET name=? WHERE id=?",[.text(name),.integer(id)])}
    func deleteCollection(_ id:Int64)async throws{try await db.transaction{db in try db.execute("UPDATE books SET collectionId=NULL,collectionOrder=0 WHERE collectionId=?",[.integer(id)]);try db.execute("DELETE FROM book_collections WHERE id=?",[.integer(id)])}}
    func tags() async throws -> [BookTag] {
        let rows = try await db.rows("SELECT * FROM book_tags ORDER BY groupName,sortOrder,createdAt")
        return rows.compactMap(Self.tag)
    }
    func tags(bookId: Int64) async throws -> [BookTag] {
        let rows = try await db.rows("SELECT t.* FROM book_tags t JOIN book_tag_refs r ON r.tagId=t.id WHERE r.bookId=? ORDER BY t.sortOrder,t.name", [.integer(bookId)])
        return rows.compactMap(Self.tag)
    }
    func tagRefs()async throws->[BookTagRef]{try await db.rows("SELECT bookId,tagId FROM book_tag_refs").compactMap{r in guard let bookId=r["bookId"]?.int64,let tagId=r["tagId"]?.int64 else{return nil};return .init(bookId:bookId,tagId:tagId)}}
    @discardableResult func createTag(name:String,colorTag:String="",groupName:String="")async throws->Int64{if let existing=try await db.rows("SELECT id FROM book_tags WHERE name=?",[.text(name)]).first?["id"]?.int64{return existing};let order=try await db.scalarInt("SELECT COALESCE(MAX(sortOrder),-1)+1 FROM book_tags") ?? 0;return try await db.execute("INSERT INTO book_tags(name,colorTag,groupName,sortOrder,createdAt) VALUES(?,?,?,?,?)",[.text(name),.text(colorTag),.text(groupName),.integer(order),.integer(now())])}
    func setTags(bookId:Int64,tagIds:[Int64])async throws{try await db.transaction{db in try db.execute("DELETE FROM book_tag_refs WHERE bookId=?",[.integer(bookId)]);for id in Set(tagIds){try db.execute("INSERT OR IGNORE INTO book_tag_refs(bookId,tagId) VALUES(?,?)",[.integer(bookId),.integer(id)])}}}
    func updateMetadata(bookId:Int64,title:String,author:String,coverPath:String?)async throws{try await db.execute("UPDATE books SET title=?,author=?,coverPath=?,metadataEdited=1 WHERE id=?",[.text(title),.text(author),coverPath.map(SQLValue.text) ?? .null,.integer(bookId)])}
    func setCoverPath(bookId:Int64,path:String?)async throws{try await db.execute("UPDATE books SET coverPath=? WHERE id=?",[path.map(SQLValue.text) ?? .null,.integer(bookId)])}
    private static func tag(_ r: [String: SQLValue]) -> BookTag? {
        guard let id = r["id"]?.int64 else { return nil }
        let sortOrder = Int(r["sortOrder"]?.int64 ?? 0)
        return .init(id: id, name: r["name"]?.string ?? "", colorTag: r["colorTag"]?.string ?? "",
                     groupName: r["groupName"]?.string ?? "", sortOrder: sortOrder,
                     createdAt: r["createdAt"]?.int64 ?? 0)
    }
    private func now()->Int64{Int64(Date().timeIntervalSince1970*1000)}
}
