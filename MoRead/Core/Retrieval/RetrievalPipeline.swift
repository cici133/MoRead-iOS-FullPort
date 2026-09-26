import Foundation

struct RetrievalChunk: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(bookId):\(chapterIndex):\(start):\(end)" }
    let bookId: Int64
    let chapterIndex: Int
    let start: Int
    let end: Int
    let text: String
    var vector: [Float]?
}

struct RetrievalHit: Identifiable, Hashable, Sendable {
    var id: String { chunk.id }
    let chunk: RetrievalChunk
    var lexicalScore: Double
    var vectorScore: Double
    var finalScore: Double
}

enum RetrievalTokenizer {
    static func tokens(_ text: String) -> [String] {
        let lower = text.lowercased()
        var output: [String] = []
        var latin = ""
        var hanRun: [Character] = []
        func flushLatin() { if !latin.isEmpty { output.append(latin); latin.removeAll(keepingCapacity: true) } }
        func flushHan() {
            guard !hanRun.isEmpty else { return }
            if hanRun.count == 1 { output.append(String(hanRun[0])) }
            else { for i in 0..<(hanRun.count - 1) { output.append(String(hanRun[i...i+1])) } }
            hanRun.removeAll(keepingCapacity: true)
        }
        for ch in lower {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { flushHan(); latin.append(ch) }
            else if ch.unicodeScalars.allSatisfy({ (0x3400...0x9fff).contains(Int($0.value)) }) { flushLatin(); hanRun.append(ch) }
            else { flushLatin(); flushHan() }
        }
        flushLatin(); flushHan()
        return output
    }
}

enum BM25 {
    static func rank(query: String, documents: [RetrievalChunk], k1: Double = 1.2, b: Double = 0.75) -> [RetrievalHit] {
        let q = Array(Set(RetrievalTokenizer.tokens(query)))
        guard !q.isEmpty, !documents.isEmpty else { return [] }
        let tokenized = documents.map { RetrievalTokenizer.tokens($0.text) }
        let avg = max(1, Double(tokenized.reduce(0) { $0 + $1.count }) / Double(tokenized.count))
        var df: [String: Int] = [:]
        for doc in tokenized { for token in Set(doc) where q.contains(token) { df[token, default: 0] += 1 } }
        return documents.indices.map { index in
            let toks = tokenized[index]
            let counts = Dictionary(toks.map { ($0, 1) }, uniquingKeysWith: +)
            var score = 0.0
            for term in q {
                let f = Double(counts[term] ?? 0); guard f > 0 else { continue }
                let n = Double(df[term] ?? 0), N = Double(documents.count)
                let idf = log(1 + (N - n + 0.5) / (n + 0.5))
                let denom = f + k1 * (1 - b + b * Double(toks.count) / avg)
                score += idf * (f * (k1 + 1)) / denom
            }
            return RetrievalHit(chunk: documents[index], lexicalScore: score, vectorScore: 0, finalScore: score)
        }.filter { $0.finalScore > 0 }.sorted { $0.finalScore > $1.finalScore }
    }
}

actor BookCorpus {
    static let shared = BookCorpus()
    private let library = LibraryRepository.shared

    func chunks(bookId: Int64, scope: ReadingScope, targetChars: Int = 900, overlap: Int = 120) async throws -> [RetrievalChunk] {
        let chapters = try await library.chapters(bookId: bookId)
        var result: [RetrievalChunk] = []
        for chapter in chapters where scope.allowsChapter(chapter.chapterIndex) {
            let body = scope.readableText(chapterIndex: chapter.chapterIndex, text: try await library.chapterText(chapter))
            let length = (body as NSString).length
            var start = 0
            while start < length {
                var end = min(length, start + max(200, targetChars))
                if end < length {
                    let ns = body as NSString
                    let floor = min(end, start + targetChars / 2)
                    for i in stride(from: end - 1, through: floor, by: -1) {
                        let c = ns.character(at: i)
                        if c == 10 || c == 0x3002 || c == 0xff01 || c == 0xff1f { end = i + 1; break }
                    }
                }
                guard end > start else { break }
                let text = (body as NSString).substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result.append(.init(bookId: bookId, chapterIndex: chapter.chapterIndex, start: start, end: end, text: text, vector: nil)) }
                if end == length { break }
                start = max(start + 1, end - max(0, overlap))
            }
        }
        return result
    }
}

actor VectorIndexStore {
    static let shared = VectorIndexStore()
    struct Snapshot: Codable { var revision: String; var modelKey: String; var chunks: [RetrievalChunk] }
    private func url(bookId: Int64) throws -> URL {
        let root = try MoReadDatabase.applicationDirectory().appendingPathComponent("book-index", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("\(bookId).plist")
    }
    func load(bookId:Int64,revision:String,modelKey:String)throws->[RetrievalChunk]?{
        let u=try url(bookId:bookId);guard let d=try? Data(contentsOf:u),let s=try? PropertyListDecoder().decode(Snapshot.self,from:d),s.revision==revision,s.modelKey==modelKey else{return nil};return s.chunks
    }
    func save(bookId:Int64,revision:String,modelKey:String,chunks:[RetrievalChunk])throws{let enc=PropertyListEncoder();enc.outputFormat = .binary;let data=try enc.encode(Snapshot(revision:revision,modelKey:modelKey,chunks:chunks));try data.write(to:url(bookId:bookId),options:.atomic)}
    func remove(bookId:Int64)throws{try? FileManager.default.removeItem(at:url(bookId:bookId))}
    func removeAll()throws{let root=try MoReadDatabase.applicationDirectory().appendingPathComponent("book-index");try? FileManager.default.removeItem(at:root)}
}

enum VectorMath {
    static func cosine(_ a:[Float],_ b:[Float])->Double{guard a.count==b.count,!a.isEmpty else{return 0};var dot=0.0,aa=0.0,bb=0.0;for i in a.indices{let x=Double(a[i]),y=Double(b[i]);dot+=x*y;aa+=x*x;bb+=y*y};guard aa>0,bb>0 else{return 0};return dot/(sqrt(aa)*sqrt(bb))}
}

actor EmbeddingIndexBuilder {
    static let shared = EmbeddingIndexBuilder()
    func index(bookId:Int64,scope:ReadingScope = .wholeBook)async throws->[RetrievalChunk]{
        let revision=try await LibraryRepository.shared.contentRevision(bookId:bookId)
        let resolved=try await AIClientFactory.forRole(.embedding)
        let modelKey="\(resolved.provider.id):\(resolved.modelName)"
        if let cached=try await VectorIndexStore.shared.load(bookId:bookId,revision:revision,modelKey:modelKey){return cached}
        var chunks=try await BookCorpus.shared.chunks(bookId:bookId,scope:scope)
        let batch=32
        for start in stride(from:0,to:chunks.count,by:batch){let end=min(chunks.count,start+batch);let vectors=try await resolved.client.embed(texts:Array(chunks[start..<end].map(\.text)));guard vectors.count==end-start else{throw AIClientError.malformed("embedding 数量与输入不一致")};for i in start..<end{chunks[i].vector=vectors[i-start]}}
        try await VectorIndexStore.shared.save(bookId:bookId,revision:revision,modelKey:modelKey,chunks:chunks)
        return chunks
    }
}

actor RetrievalPipeline {
    static let shared = RetrievalPipeline()
    func search(bookId:Int64,query:String,scope:ReadingScope,limit:Int=8,useEmbedding:Bool=true)async throws->[RetrievalHit]{
        let local=try await BookCorpus.shared.chunks(bookId:bookId,scope:scope)
        let lexical=BM25.rank(query:query,documents:local)
        guard useEmbedding else{return Array(lexical.prefix(limit))}
        guard let resolved=try? await AIClientFactory.forRole(.embedding),let qv=try? await resolved.client.embed(texts:[query]).first else{return Array(lexical.prefix(limit))}
        let indexed=(try? await EmbeddingIndexBuilder.shared.index(bookId:bookId,scope:.wholeBook)) ?? []
        var byId=Dictionary(uniqueKeysWithValues:lexical.map{($0.id,$0)})
        for chunk in indexed where scope.allowsChunk(chapterIndex:chunk.chapterIndex,startCharOffset:chunk.start,endCharOffset:chunk.end) {
            guard let v=chunk.vector else{continue};let score=VectorMath.cosine(qv,v);var hit=byId[chunk.id] ?? .init(chunk:chunk,lexicalScore:0,vectorScore:0,finalScore:0);hit.vectorScore=score;hit.finalScore=0.45*hit.lexicalScore+0.55*max(0,score);byId[chunk.id]=hit
        }
        let fused = Array(byId.values.sorted { $0.finalScore > $1.finalScore }.prefix(max(limit * 3, 20)))
        if (try? await AIProviderRepository.shared.assignment(.rerank)) != nil {
            return (try? await RerankClient.shared.rerank(query: query, hits: fused, topN: limit)) ?? Array(fused.prefix(limit))
        }
        return Array(fused.prefix(limit))
    }
}

actor BookGrep {
    static let shared = BookGrep()
    struct Match:Identifiable,Hashable,Sendable{var id:String{"\(chapterIndex):\(start)"};let chapterIndex:Int;let start:Int;let end:Int;let excerpt:String}
    struct Report:Sendable{let matches:[Match];let totalMatches:Int;let returnedMatches:Int;let complete:Bool;let exact:Bool}

    /// Literal scan over the entire readable scope. We keep counting after the return-list limit so
    /// agents can distinguish an exact total from a truncated evidence list.
    func report(bookId:Int64,query:String,scope:ReadingScope,limit:Int=100)async throws->Report{
        let needle=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !needle.isEmpty else{return .init(matches:[],totalMatches:0,returnedMatches:0,complete:true,exact:true)}
        let chapters=try await LibraryRepository.shared.chapters(bookId:bookId)
        var out:[Match]=[],total=0
        for c in chapters where scope.allowsChapter(c.chapterIndex){
            try Task.checkCancellation()
            let body=scope.readableText(chapterIndex:c.chapterIndex,text:try await LibraryRepository.shared.chapterText(c))
            let ns=body as NSString;var range=NSRange(location:0,length:ns.length)
            while range.length>0,let r=ns.range(of:needle,options:[.caseInsensitive],range:range).nonNotFound{
                total += 1
                if out.count < max(0,limit){let a=max(0,r.location-80),b=min(ns.length,NSMaxRange(r)+120);out.append(.init(chapterIndex:c.chapterIndex,start:r.location,end:NSMaxRange(r),excerpt:ns.substring(with:NSRange(location:a,length:b-a))))}
                let next=NSMaxRange(r);if next<=r.location{break};range=NSRange(location:next,length:max(0,ns.length-next))
            }
        }
        return .init(matches:out,totalMatches:total,returnedMatches:out.count,complete:true,exact:true)
    }
    func grep(bookId:Int64,query:String,scope:ReadingScope,limit:Int=100)async throws->[Match]{try await report(bookId:bookId,query:query,scope:scope,limit:limit).matches}
}
private extension NSRange{var nonNotFound:NSRange?{location==NSNotFound ? nil:self}}
