import Foundation

actor MemoryRepository {
    static let shared = MemoryRepository()
    private struct Snapshot:Codable{var values:[LongTermMemory]}
    private func url() throws -> URL { try MoReadDatabase.applicationDirectory().appendingPathComponent("memory.plist") }
    private func load() throws -> [LongTermMemory] { guard let d=try? Data(contentsOf:url()),let s=try? PropertyListDecoder().decode(Snapshot.self,from:d) else{return []};return s.values }
    private func save(_ values:[LongTermMemory]) throws { let e=PropertyListEncoder();e.outputFormat = .binary;try e.encode(Snapshot(values:values)).write(to:url(),options:.atomic) }

    func all(personaId:Int64,bookId:Int64?,maskId:Int64)->[LongTermMemory]{let values=(try? load()) ?? [];return values.filter{$0.personaId==personaId && $0.maskId==maskId && (bookId==nil || $0.bookId==nil || $0.bookId==bookId)}}
    func add(personaId:Int64,bookId:Int64?,maskId:Int64,summary:String,conversationId:Int64,through:Int64,embedding:[Float]?=nil)throws{var v=try load();let now=Self.now();v.append(.init(id:UUID(),personaId:personaId,bookId:bookId,maskId:maskId,summary:String(summary.prefix(500)),sourceConversationId:conversationId,sourceThroughMessageId:through,embedding:embedding,createdAt:now,updatedAt:now));try save(v)}
    func apply(_ ops:[MemoryOperation],personaId:Int64,bookId:Int64?,maskId:Int64,conversationId:Int64,through:Int64)throws{var v=try load();let now=Self.now();for op in ops{switch op{case .add(let s):v.append(.init(id:UUID(),personaId:personaId,bookId:bookId,maskId:maskId,summary:s,sourceConversationId:conversationId,sourceThroughMessageId:through,embedding:nil,createdAt:now,updatedAt:now));case .update(let id,let s):if let i=v.firstIndex(where:{$0.id==id && $0.personaId==personaId && $0.maskId==maskId}){v[i].summary=s;v[i].updatedAt=now;v[i].embedding=nil};case .delete(let id):v.removeAll{$0.id==id && $0.personaId==personaId && $0.maskId==maskId}}};try save(v)}
    func remove(bookId: Int64) throws {
        var values = try load()
        values.removeAll { $0.bookId == bookId }
        try save(values)
    }

    func remove(conversationIds: Set<Int64>) throws {
        guard !conversationIds.isEmpty else { return }
        var values = try load()
        values.removeAll { conversationIds.contains($0.sourceConversationId) }
        try save(values)
    }

    func search(query:String,personaId:Int64,bookId:Int64?,maskId:Int64,limit:Int=6)async->[LongTermMemory]{var rows=all(personaId:personaId,bookId:bookId,maskId:maskId);guard !rows.isEmpty else{return []};let lexical=BM25.rank(query:query,documents:rows.enumerated().map{RetrievalChunk(bookId:Int64($0.offset),chapterIndex:0,start:0,end:($0.element.summary as NSString).length,text:$0.element.summary,vector:$0.element.embedding)});let lexicalIds=Set(lexical.prefix(limit*2).map{Int($0.chunk.bookId)});if let resolved=try? await AIClientFactory.forRole(.embedding),let q=try? await resolved.client.embed(texts:[query]).first{for i in rows.indices where rows[i].embedding==nil{rows[i].embedding=(try? await resolved.client.embed(texts:[rows[i].summary]).first) ?? nil};try? save(rows);return Array(rows.enumerated().sorted{a,b in let la=lexicalIds.contains(a.offset) ? 0.2:0;let lb=lexicalIds.contains(b.offset) ? 0.2:0;return la+VectorMath.cosine(q,a.element.embedding ?? []) > lb+VectorMath.cosine(q,b.element.embedding ?? [])}.prefix(limit).map(\.element))};return lexical.prefix(limit).compactMap{h in rows.indices.contains(Int(h.chunk.bookId)) ? rows[Int(h.chunk.bookId)]:nil}}
    private static func now()->Int64{Int64(Date().timeIntervalSince1970*1000)}
}

actor MemoryConsolidationService {
    static let shared = MemoryConsolidationService()
    func updateRollingSummary(conversation:AIConversationRecord)async throws{
        let repo=AIConversationRepository.shared;let messages=try await repo.messages(conversationId:conversation.id)
        guard let work=RollingSummaryPlanner.plan(messages:messages,consolidatedThrough:conversation.memoryConsolidatedThroughMessageId,summarizedThrough:conversation.summarizedThroughMessageId) else{return}
        let resolved=try await AIClientFactory.forRole(.cheap)
        let prompt="""
        把下面新增对话与旧摘要合并成不超过 \(RollingSummaryPlanner.maxSummaryChars) 字的连续前情提要。只保留稳定事实、人物关系、用户偏好和未解决事项，不编造。
        旧摘要：\(conversation.rollingSummary)
        新对话：\n\(RollingSummaryPlanner.transcript(work))
        """
        let text=try await resolved.client.chat(messages:[.init(role:.user,content:prompt)],options:resolved.options)
        try await MoReadDatabase.shared.execute("UPDATE conversations SET rollingSummary=?,summarizedThroughMessageId=?,updatedAt=? WHERE id=?",[.text(String(text.prefix(RollingSummaryPlanner.maxSummaryChars))),.integer(work.throughMessageId),.integer(Int64(Date().timeIntervalSince1970*1000)),.integer(conversation.id)])
    }

    func consolidate(conversation:AIConversationRecord,personaId:Int64,maskId:Int64,bookId:Int64?)async throws{
        let messages=try await AIConversationRepository.shared.messages(conversationId:conversation.id).filter{$0.id>conversation.memoryConsolidatedThroughMessageId && ($0.role=="user"||$0.role=="assistant")}
        guard messages.count>=30 else{return};let batch=Array(messages.prefix(40));let transcript=batch.map{($0.role=="user" ? "用户：":"我：") + String($0.content.prefix(1200))}.joined(separator:"\n")
        let existing=await MemoryRepository.shared.all(personaId:personaId,bookId:bookId,maskId:maskId)
        let prompt="""
        从对话中提炼可长期记住的信息。已有记忆如下：\n\(existing.map{"\($0.id.uuidString) | \($0.summary)"}.joined(separator:"\n"))
        新对话：\n\(transcript)
        只输出 JSON 数组，每项 action 为 ADD/UPDATE/DELETE，UPDATE/DELETE 必须带已有 UUID id；只有明确冲突或被取代才更新删除，拿不准就 ADD。summary 不超过 500 字。
        """
        let resolved=try await AIClientFactory.forRole(.cheap);let raw=try await resolved.client.chat(messages:[.init(role:.user,content:prompt)],options:resolved.options);let ops=MemoryOperation.parse(raw);let through=batch.last!.id
        try await MemoryRepository.shared.apply(ops,personaId:personaId,bookId:bookId,maskId:maskId,conversationId:conversation.id,through:through)
        if maskId == 0 { try? await updateUserProfile(personaId: personaId, batch: batch) }
        try await MoReadDatabase.shared.execute("UPDATE conversations SET memoryConsolidatedThroughMessageId=?,summarizedThroughMessageId=MAX(summarizedThroughMessageId,?),updatedAt=? WHERE id=?",[.integer(through),.integer(through),.integer(Int64(Date().timeIntervalSince1970*1000)),.integer(conversation.id)])
    }

    private func updateUserProfile(personaId: Int64, batch: [AIStoredMessage]) async throws {
        guard let persona = try await PersonaRepository.shared.persona(id: personaId) else { return }
        let userOnly = batch.filter { $0.role == "user" }.map { "- " + String($0.content.prefix(1600)) }.joined(separator: "\n")
        guard !userOnly.isEmpty else { return }
        let prompt = """
        维护一份关于真实用户本人的长期画像。只保留相对稳定且由用户本人明确透露或反复表现的信息，例如称呼、偏好与雷点、阅读口味、交流习惯、关系进展和长期约定。不要把书中人物、剧情内容、临时情绪、猜测或角色扮演设定写进去。输出完整替换后的 Markdown 画像，最多 6000 字；没有可靠新信息时原样返回旧画像。
        旧画像：
        \(persona.userProfile)

        新的用户消息：
        \(userOnly)
        """
        let resolved = try await AIClientFactory.forRole(.cheap)
        let profile = try await resolved.client.chat(messages: [.init(role:.user,content:prompt)],options:resolved.options)
        try await PersonaRepository.shared.updateUserProfile(personaId: personaId, profile: profile)
    }
}
