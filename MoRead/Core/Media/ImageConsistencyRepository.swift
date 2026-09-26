import Foundation

struct ImageStyleTemplateRecord: Identifiable, Hashable, Sendable { var id: String; var name: String; var style: StyleSpec; var updatedAt: Int64 }

actor ImageConsistencyRepository {
    static let shared = ImageConsistencyRepository()
    private let db = MoReadDatabase.shared
    private let encoder = JSONEncoder(), decoder = JSONDecoder()

    func style(bookId: Int64) async throws -> StyleSpec {
        guard let raw = try await db.rows("SELECT specJson FROM book_image_styles WHERE bookId=?", [.integer(bookId)]).first?["specJson"]?.string,
              let data = raw.data(using: .utf8), let value = try? decoder.decode(StyleSpec.self, from: data) else { return .init() }
        return value
    }
    func saveStyle(bookId: Int64, _ style: StyleSpec) async throws {
        try validate(style); let raw = String(decoding: try encoder.encode(style), as: UTF8.self)
        try await db.execute("INSERT INTO book_image_styles(bookId,specJson) VALUES(?,?) ON CONFLICT(bookId) DO UPDATE SET specJson=excluded.specJson", [.integer(bookId), .text(raw)])
    }
    func templates() async throws -> [ImageStyleTemplateRecord] {
        try await db.rows("SELECT * FROM image_style_templates ORDER BY updatedAt DESC").compactMap { row in
            guard let id=row["id"]?.string, let name=row["name"]?.string, let raw=row["specJson"]?.string, let d=raw.data(using:.utf8), let style=try? decoder.decode(StyleSpec.self,from:d) else{return nil}
            return .init(id:id,name:name,style:style,updatedAt:row["updatedAt"]?.int64 ?? 0)
        }
    }
    func saveTemplate(name: String, style: StyleSpec, id: String? = nil) async throws {
        try validate(style); let clean=name.trimmingCharacters(in:.whitespacesAndNewlines); guard !clean.isEmpty, clean.utf16.count<=80 else{throw ImageGenerationError.unsupported("模板名称需为 1–80 字")}
        let key=id ?? UUID().uuidString; let raw=String(decoding:try encoder.encode(style),as:UTF8.self); try await db.execute("INSERT INTO image_style_templates(id,name,specJson,updatedAt) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,specJson=excluded.specJson,updatedAt=excluded.updatedAt",[.text(key),.text(clean),.text(raw),.integer(Self.now())])
    }
    func deleteTemplate(id:String) async throws { try await db.execute("DELETE FROM image_style_templates WHERE id=?",[.text(id)]) }

    func looks(bookId:Int64) async throws->[LookSpec]{try await db.rows("SELECT specJson FROM character_looks WHERE bookId=? ORDER BY characterKey,sinceChapter",[.integer(bookId)]).compactMap{r in guard let raw=r["specJson"]?.string,let d=raw.data(using:.utf8) else{return nil};return try? decoder.decode(LookSpec.self,from:d)}}
    func saveLook(bookId:Int64,_ look:LookSpec)async throws{guard look.sinceChapter>=0,!look.characterKey.isEmpty,look.referenceIds.count<=3,look.natural.utf16.count<=12000,look.tags.utf16.count<=12000 else{throw ImageGenerationError.unsupported("人物形象参数无效")};let raw=String(decoding:try encoder.encode(look),as:UTF8.self);let existing=try await db.rows("SELECT id FROM character_looks WHERE bookId=? AND characterKey=? AND sinceChapter=? LIMIT 1",[.integer(bookId),.text(look.characterKey),.integer(Int64(look.sinceChapter))]).first?["id"]?.string;let stable=existing ?? look.id;try await db.execute("INSERT INTO character_looks(id,bookId,characterKey,sinceChapter,specJson) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET specJson=excluded.specJson",[.text(stable),.integer(bookId),.text(look.characterKey),.integer(Int64(look.sinceChapter)),.text(raw)])}
    func deleteLook(id:String)async throws{try await db.execute("DELETE FROM character_looks WHERE id=?",[.text(id)])}

    func visibleLook(_ values:[LookSpec],characterKey:String,chapterIndex:Int)->LookSpec?{values.filter{$0.characterKey==characterKey && $0.sinceChapter<=chapterIndex}.sorted{a,b in a.sinceChapter==b.sinceChapter ? a.id>b.id:a.sinceChapter>b.sinceChapter}.first}

    func turnaroundCandidates(bookId:Int64,chapterIndex:Int,look:LookSpec,count:Int=4) async throws -> [GeneratedIllustration] {
        guard (1...4).contains(count) else { throw ImageGenerationError.unsupported("人物候选数量应为 1–4") }
        guard let book=try await LibraryRepository.shared.book(id:bookId), chapterIndex<=book.maxReachedChapterIndex else {
            throw ImageGenerationError.unsupported("只能基于已读范围生成人物参考图")
        }
        let savedStyle=try await style(bookId:bookId)
        let caps=await ImageGenerationService.shared.capabilities()
        let refs=ImageRecipeLogic.planReferences(capabilities:caps,cast:[look],style:savedStyle,enabled:true).references
        let shot=ShotSpec(
            cast:[look.characterKey],
            action:"standing, neutral pose, consistent outfit and identity",
            setting:"plain studio background",
            composition:"multiple views, turnaround, reference sheet, front view, three-quarter view, side view, back view, full body, face close-up in corner, no text",
            lighting:"soft even studio lighting",
            mood:"neutral character design reference"
        )
        let size=caps.tags ? "832x1216" : "1024x1536"
        let seed=caps.seed ? Int64.random(in:0...0xffff_ffff) : nil
        let recipe=ImageRecipe(style:savedStyle,cast:[look],shot:shot,references:refs,seed:seed,size:size,backend:await ImageGenerationService.shared.backendLabel())
        var output:[GeneratedIllustration]=[]
        do {
            for index in 0..<count {
                try Task.checkCancellation()
                var variant=recipe
                if let seed { variant.seed=(seed+Int64(index)) & 0xffff_ffff }
                output.append(try await ImageGenerationService.shared.generate(
                    bookId:bookId,chapterIndex:chapterIndex,charOffset:nil,sourceText:look.natural.isEmpty ? look.tags : look.natural,
                    recipe:variant,persist:false
                ))
            }
            return output
        } catch {
            output.forEach { try? FileManager.default.removeItem(atPath:$0.imagePath) }
            throw error
        }
    }

    func plan(bookId:Int64,chapterIndex:Int,source:String,useReferences:Bool=true,size:String?=nil)async throws->ImageRecipe{
        guard let book=try await LibraryRepository.shared.book(id:bookId),chapterIndex<=book.maxReachedChapterIndex else{throw ImageGenerationError.unsupported("只能为已读场景生成插图")}
        let savedStyle=try await style(bookId:bookId), savedLooks=try await looks(bookId:bookId)
        let guide=try await BookCharacterRepository.shared.published(bookId:bookId,scope:.uptoProgress(book:book),allowBeyondProgress:false)
        let people=guide?.characters ?? []
        let keys=people.filter{person in ([person.name]+person.attributes.filter{$0.kind == .alias}.map(\.value)).contains{source.contains($0)}}.map(\.name)
        var shot=ShotSpec(cast:keys,action:String(source.prefix(8000)))
        if let resolved=try? await AIClientFactory.forRole(.cheap){
            let known=people.map{["id":$0.name,"name":$0.name]};let prompt="Plan one novel illustration. Return only JSON {cast:[known ids],action,setting,composition,lighting,mood}. Do not describe fixed appearance or invent plot. Known cast: \(known)\nScene: \(String(source.prefix(12000)))"
            if let raw=try? await resolved.client.chat(messages:[.init(role:.user,content:prompt)],options:resolved.options),let data=Self.cleanJSON(raw).data(using:.utf8),let parsed=try? decoder.decode(ShotSpec.self,from:data){shot=parsed;shot.cast=shot.cast.filter { key in keys.contains(key) || people.contains { $0.name == key } }}
        }
        let cast=shot.cast.compactMap{key->LookSpec? in
            if let saved=visibleLook(savedLooks,characterKey:key,chapterIndex:chapterIndex){return saved}
            guard let person=people.first(where:{$0.name==key}) else{return nil}
            let appearances=person.attributes.filter{$0.kind == .appearance}.map{LookAttribute(label:"appearance",value:$0.value,chapterIndex:nil,start:nil,end:nil,quote:$0.fact.quote)}
            return LookSpec(id:UUID().uuidString,characterKey:person.name,name:person.name,sinceChapter:0,natural:appearances.map(\.value).joined(separator:"; "),attributes:appearances,source:appearances.isEmpty ? "manual":"text")
        }
        let caps=await ImageGenerationService.shared.capabilities()
        let refs=ImageRecipeLogic.planReferences(capabilities:caps,cast:cast,style:savedStyle,enabled:useReferences)
        let resolvedSize: String?
        if let size { resolvedSize = size }
        else { resolvedSize = await ImageGenerationService.shared.defaultSize() }
        let backend = await ImageGenerationService.shared.backendLabel()
        let seed = caps.seed ? (savedStyle.seed ?? Int64.random(in: 0...0xffff_ffff)) : nil
        return .init(style: savedStyle, cast: cast, shot: shot, references: refs.references,
                     seed: seed, size: resolvedSize, backend: backend)
    }

    private func validate(_ s:StyleSpec)throws{guard s.referenceIds.count<=3,s.natural.utf16.count<=8000,s.tags.utf16.count<=8000,s.seed.map({$0>=0 && $0<=0xffff_ffff}) ?? true else{throw ImageGenerationError.unsupported("画风参数无效")}}
    private static func cleanJSON(_ raw:String)->String{raw.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"```json",with:"").replacingOccurrences(of:"```",with:"").trimmingCharacters(in:.whitespacesAndNewlines)}
    private static func now()->Int64{Int64(Date().timeIntervalSince1970*1000)}
}
