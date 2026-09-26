import Foundation

actor AudiobookRepository {
    static let shared=AudiobookRepository();private let db=MoReadDatabase.shared
    func roles(bookId:Int64)async throws->[AudiobookRole]{try await db.rows("SELECT * FROM audiobook_roles WHERE bookId=? ORDER BY sortOrder,id",[.integer(bookId)]).compactMap(Self.role)}
    @discardableResult func saveRole(_ x:AudiobookRole)async throws->Int64{
        if x.id>0{let old=try await role(id:x.id);if old?.engine != x.engine || old?.voiceId != x.voiceId{try await clearAudio(roleId:x.id,bookId:x.bookId)};try await db.execute("UPDATE audiobook_roles SET name=?,aliases=?,kind=?,gender=?,engine=?,voiceId=?,extraJson=?,color=?,sortOrder=?,source=? WHERE id=?",[.text(x.name),.text(x.aliases.joined(separator:"|")),.text(x.kind.rawValue),.text(x.gender),.text(x.engine.rawValue),.text(x.voiceId),.text(x.extraJSON),.text(x.color),.integer(Int64(x.sortOrder)),.text("USER"),.integer(x.id)]);return x.id}
        return try await db.execute("INSERT INTO audiobook_roles(bookId,name,aliases,kind,gender,engine,voiceId,extraJson,color,sortOrder,source) VALUES(?,?,?,?,?,?,?,?,?,?,?)",[.integer(x.bookId),.text(x.name),.text(x.aliases.joined(separator:"|")),.text(x.kind.rawValue),.text(x.gender),.text(x.engine.rawValue),.text(x.voiceId),.text(x.extraJSON),.text(x.color),.integer(Int64(x.sortOrder)),.text(x.source)])
    }
    func role(id:Int64)async throws->AudiobookRole?{try await db.rows("SELECT * FROM audiobook_roles WHERE id=?",[.integer(id)]).first.flatMap(Self.role)}
    func replaceRoles(bookId:Int64,_ proposed:[AudiobookRole])async throws{
        let existing=try await roles(bookId:bookId);var retained=Set<Int64>()
        for role in proposed{
            let aliases=Set(([role.name]+role.aliases).map{$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}.filter{!$0.isEmpty})
            let match=existing.filter{old in old.kind == .narrator && role.kind == .narrator || !Set(([old.name]+old.aliases).map{$0.lowercased()}).isDisjoint(with:aliases)}
            if match.count == 1{let old=match[0];retained.insert(old.id);if old.source != "USER"{var updated=old;updated.aliases=Array(Set(old.aliases+role.aliases+[role.name])).filter{$0 != old.name};if !role.gender.isEmpty{updated.gender=role.gender};updated.extraJSON=role.extraJSON.isEmpty ? old.extraJSON:role.extraJSON;_ = try await saveRole(updated)}}else if match.isEmpty{var fresh=role;fresh.id=0;_ = try await saveRole(fresh)}
        }
    }
    func deleteRole(_ id:Int64)async throws{if let r=try await role(id:id){try await clearAudio(roleId:id,bookId:r.bookId)};try await db.execute("UPDATE audiobook_segments SET roleId=NULL WHERE roleId=?",[.integer(id)]);try await db.execute("DELETE FROM audiobook_roles WHERE id=?",[.integer(id)])}
    func applyPolicy(bookId:Int64,_ policy:AudiobookEnginePolicy)async throws{guard policy != .custom else{return};for var role in try await roles(bookId:bookId){let engine=policy.engine(for:role.kind);if role.engine != engine{role.engine=engine;role.voiceId="";_ = try await saveRole(role)}}}

    func segments(bookId:Int64,chapterIndex:Int)async throws->[AudiobookSegment]{try await db.rows("SELECT * FROM audiobook_segments WHERE bookId=? AND chapterIndex=? ORDER BY startCharOffset,id",[.integer(bookId),.integer(Int64(chapterIndex))]).compactMap(Self.segment)}
    func replaceSegments(bookId:Int64,chapterIndex:Int,_ values:[AudiobookSegment],confirmed:Bool=false)async throws{
        try await db.transaction{db in
            try db.execute("DELETE FROM audiobook_segments WHERE bookId=? AND chapterIndex=?",[.integer(bookId),.integer(Int64(chapterIndex))])
            for x in values{_ = try db.execute("INSERT INTO audiobook_segments(bookId,chapterIndex,startCharOffset,endCharOffset,roleId,emotion,instruction,audioPath,audioMillis,revision) VALUES(?,?,?,?,?,?,?,?,?,?)",[.integer(bookId),.integer(Int64(chapterIndex)),.integer(Int64(x.start)),.integer(Int64(x.end)),x.roleId.map(SQLValue.integer) ?? .null,x.emotion.map(SQLValue.text) ?? .null,x.instruction.map(SQLValue.text) ?? .null,x.audioPath.map(SQLValue.text) ?? .null,.integer(x.audioMillis),.integer(Int64(x.revision))])}
            let now=Self.now();try db.execute("INSERT INTO audiobook_chapters(bookId,chapterIndex,state,scriptedAt,confirmedAt,synthesizedAt,segmentCount,readySegmentCount,totalMillis) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(bookId,chapterIndex) DO UPDATE SET state=excluded.state,scriptedAt=excluded.scriptedAt,confirmedAt=excluded.confirmedAt,synthesizedAt=0,segmentCount=excluded.segmentCount,readySegmentCount=0,totalMillis=0",[.integer(bookId),.integer(Int64(chapterIndex)),.text(confirmed ? AudiobookChapterStatus.confirmed.rawValue:AudiobookChapterStatus.scripted.rawValue),.integer(now),.integer(confirmed ? now:0),.integer(0),.integer(Int64(values.count)),.integer(0),.integer(0)])
        }
    }
    func updateSegment(_ x:AudiobookSegment)async throws{
        let old=try await db.rows("SELECT roleId,emotion,instruction,audioPath FROM audiobook_segments WHERE id=?",[.integer(x.id)]).first
        let changed=old?["roleId"]?.int64 != x.roleId || old?["emotion"]?.string != x.emotion || old?["instruction"]?.string != x.instruction
        if changed,let path=old?["audioPath"]?.string,!path.isEmpty{try? FileManager.default.removeItem(atPath:path)}
        try await db.execute("UPDATE audiobook_segments SET roleId=?,emotion=?,instruction=?,audioPath=?,audioMillis=?,revision=? WHERE id=?",[x.roleId.map(SQLValue.integer) ?? .null,x.emotion.map(SQLValue.text) ?? .null,x.instruction.map(SQLValue.text) ?? .null,changed ? .null:(x.audioPath.map(SQLValue.text) ?? .null),.integer(changed ? 0:x.audioMillis),.integer(Int64(x.revision)),.integer(x.id)])
        try await setChapterStatus(bookId:x.bookId,chapterIndex:x.chapterIndex,status:.scripted,ready:0,totalMillis:0)
    }
    func confirmScript(bookId:Int64,chapterIndex:Int)async throws{guard let current=try await chapterState(bookId:bookId,chapterIndex:chapterIndex) else{return};try await upsertChapter(current,status:.confirmed,confirmedAt:Self.now())}
    func markAudio(segmentId:Int64,path:String,millis:Int64)async throws{try await db.execute("UPDATE audiobook_segments SET audioPath=?,audioMillis=? WHERE id=?",[.text(path),.integer(millis),.integer(segmentId)])}
    func clearAudio(segmentId:Int64)async throws{if let p=try await db.rows("SELECT audioPath FROM audiobook_segments WHERE id=?",[.integer(segmentId)]).first?["audioPath"]?.string,!p.isEmpty{try? FileManager.default.removeItem(atPath:p)};try await db.execute("UPDATE audiobook_segments SET audioPath=NULL,audioMillis=0 WHERE id=?",[.integer(segmentId)])}
    func chapterState(bookId:Int64,chapterIndex:Int)async throws->AudiobookChapterState?{guard let r=try await db.rows("SELECT * FROM audiobook_chapters WHERE bookId=? AND chapterIndex=?",[.integer(bookId),.integer(Int64(chapterIndex))]).first else{return nil};return Self.chapter(r)}
    func chapterStates(bookId:Int64)async throws->[AudiobookChapterState]{try await db.rows("SELECT * FROM audiobook_chapters WHERE bookId=? ORDER BY chapterIndex",[.integer(bookId)]).compactMap(Self.chapter)}
    func setChapterStatus(bookId:Int64,chapterIndex:Int,status:AudiobookChapterStatus,ready:Int?=nil,totalMillis:Int64?=nil)async throws{guard let current=try await chapterState(bookId:bookId,chapterIndex:chapterIndex) else{return};var next=current;next.state=status.rawValue;if let ready{next.readySegmentCount=ready};if let totalMillis{next.totalMillis=totalMillis};if status == .ready{next.synthesizedAt=Self.now()};try await upsertChapter(next,status:status)}
    func markStale(bookId:Int64,chapterIndex:Int)async throws{try await setChapterStatus(bookId:bookId,chapterIndex:chapterIndex,status:.stale)}

    private func clearAudio(roleId:Int64,bookId:Int64)async throws{let rows=try await db.rows("SELECT id,audioPath,chapterIndex FROM audiobook_segments WHERE bookId=? AND roleId=?",[.integer(bookId),.integer(roleId)]);for r in rows{if let p=r["audioPath"]?.string,!p.isEmpty{try? FileManager.default.removeItem(atPath:p)}};try await db.execute("UPDATE audiobook_segments SET audioPath=NULL,audioMillis=0 WHERE bookId=? AND roleId=?",[.integer(bookId),.integer(roleId)]);for idx in Set(rows.compactMap{$0["chapterIndex"]?.int64.map(Int.init)}){try? await setChapterStatus(bookId:bookId,chapterIndex:idx,status:.confirmed,ready:0,totalMillis:0)}}
    private func upsertChapter(_ x:AudiobookChapterState,status:AudiobookChapterStatus,confirmedAt:Int64?=nil)async throws{try await db.execute("INSERT INTO audiobook_chapters(bookId,chapterIndex,state,scriptedAt,confirmedAt,synthesizedAt,segmentCount,readySegmentCount,totalMillis) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(bookId,chapterIndex) DO UPDATE SET state=excluded.state,scriptedAt=excluded.scriptedAt,confirmedAt=excluded.confirmedAt,synthesizedAt=excluded.synthesizedAt,segmentCount=excluded.segmentCount,readySegmentCount=excluded.readySegmentCount,totalMillis=excluded.totalMillis",[.integer(x.bookId),.integer(Int64(x.chapterIndex)),.text(status.rawValue),.integer(x.scriptedAt),.integer(confirmedAt ?? x.confirmedAt),.integer(x.synthesizedAt),.integer(Int64(x.segmentCount)),.integer(Int64(x.readySegmentCount)),.integer(x.totalMillis)])}
    private static func role(_ r: [String: SQLValue]) -> AudiobookRole? {
        guard let id = r["id"]?.int64, let bookId = r["bookId"]?.int64 else { return nil }
        let aliases: [String] = (r["aliases"]?.string ?? "").split(separator: "|").map(String.init)
        let kind: AudiobookRoleKind = AudiobookRoleKind(rawValue: r["kind"]?.string ?? "") ?? .character
        let engine: AudiobookEngine = AudiobookEngine(rawValue: r["engine"]?.string ?? "") ?? .system
        let sortOrder: Int = Int(r["sortOrder"]?.int64 ?? 0)
        let name: String = r["name"]?.string ?? ""
        let gender: String = r["gender"]?.string ?? ""
        let voiceId: String = r["voiceId"]?.string ?? ""
        let extraJSON: String = r["extraJson"]?.string ?? "{}"
        let color: String = r["color"]?.string ?? ""
        let source: String = r["source"]?.string ?? "manual"
        return AudiobookRole(id: id, bookId: bookId, name: name, aliases: aliases, kind: kind,
                             gender: gender, engine: engine, voiceId: voiceId, extraJSON: extraJSON,
                             color: color, sortOrder: sortOrder, source: source)
    }
    private static func segment(_ r: [String: SQLValue]) -> AudiobookSegment? {
        guard let id = r["id"]?.int64, let bookId = r["bookId"]?.int64 else { return nil }
        let chapterIndex = Int(r["chapterIndex"]?.int64 ?? 0)
        let start = Int(r["startCharOffset"]?.int64 ?? 0)
        let end = Int(r["endCharOffset"]?.int64 ?? 0)
        let revision = Int(r["revision"]?.int64 ?? 0)
        return .init(id: id, bookId: bookId, chapterIndex: chapterIndex, start: start, end: end,
                     roleId: r["roleId"]?.int64, emotion: r["emotion"]?.string,
                     instruction: r["instruction"]?.string, audioPath: r["audioPath"]?.string,
                     audioMillis: r["audioMillis"]?.int64 ?? 0, revision: revision)
    }
    private static func chapter(_ r: [String: SQLValue]) -> AudiobookChapterState? {
        guard let bookId = r["bookId"]?.int64 else { return nil }
        let chapterIndex: Int = Int(r["chapterIndex"]?.int64 ?? 0)
        let state: String = r["state"]?.string ?? AudiobookChapterStatus.none.rawValue
        let scriptedAt: Int64 = r["scriptedAt"]?.int64 ?? 0
        let confirmedAt: Int64 = r["confirmedAt"]?.int64 ?? 0
        let synthesizedAt: Int64 = r["synthesizedAt"]?.int64 ?? 0
        let segmentCount: Int = Int(r["segmentCount"]?.int64 ?? 0)
        let readyCount: Int = Int(r["readySegmentCount"]?.int64 ?? 0)
        let totalMillis: Int64 = r["totalMillis"]?.int64 ?? 0
        return AudiobookChapterState(bookId: bookId, chapterIndex: chapterIndex, state: state,
                                     scriptedAt: scriptedAt, confirmedAt: confirmedAt,
                                     synthesizedAt: synthesizedAt, segmentCount: segmentCount,
                                     readySegmentCount: readyCount, totalMillis: totalMillis)
    }
    private static func now()->Int64{Int64(Date().timeIntervalSince1970*1000)}
}
