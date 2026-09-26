import Foundation
import UIKit
import ZIPFoundation
import CryptoKit

struct GeneratedIllustration: Identifiable, Hashable, Sendable {
    var id: Int64 = 0
    var bookId: Int64
    var chapterIndex: Int?
    var charOffset: Int?
    var sourceText: String
    var prompt: String
    var imagePath: String
    var mediaType: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var personaId: Int64?
    var recipeJSON: String
    var castKeysJSON: String
    var createdAt: Int64
}

enum ImageGenerationError: LocalizedError {
    case invalidResponse(String), unsupported(String)
    var errorDescription: String? { switch self { case .invalidResponse(let value), .unsupported(let value): return value } }
}

actor ImageGenerationService {
    static let shared = ImageGenerationService()
    private let db = MoReadDatabase.shared

    private struct Backend: Sendable {
        var kind: ImageAPIProvider
        var label: String
        var baseURL: String
        var model: String
        var endpoint: String
        var apiKey: String
        var extraBody: [String: AnySendable]
        var extraHeaders: [String: String]
        var settings: ImageAPISettings?
    }

    func capabilities() async -> ImageCapabilities {
        guard let backend = try? await resolveBackend() else { return .init() }
        let name = backend.model.lowercased()
        switch backend.kind {
        case .novelAI:
            let v45 = name.hasPrefix("nai-diffusion-4-5"), v4 = name.hasPrefix("nai-diffusion-4"), v5 = name.hasPrefix("nai-diffusion-5")
            return .init(maxReferences: (v4 || v5) ? 3 : 0, maxCharacterReferences: v45 ? 1 : 0,
                         maxCharacters: v5 ? 22 : (v4 ? 6 : .max), perCharacterPrompt: v4 || v5,
                         seed: true, vibe: v4 || v5, exclusiveCharacterAndStyle: true,
                         characterReferenceCost: 5, tags: true, multilingual: v5)
        case .openAIChat:
            let gemini = name.contains("gemini") && name.contains("image")
            let gemini3 = gemini && name.contains("gemini-3")
            return .init(maxReferences: gemini3 ? 14 : (gemini ? 3 : 4), maxCharacterReferences: gemini3 ? (name.contains("pro") ? 5 : 4) : (gemini ? 3 : 4))
        case .openAIImages:
            let gpt = name.hasPrefix("gpt-image-")
            return .init(maxReferences: gpt ? 16 : 0, maxCharacterReferences: gpt ? 16 : 0)
        }
    }

    func defaultSize() async -> String {
        guard let backend = try? await resolveBackend() else { return "1024x1024" }
        if let settings = backend.settings { return settings.effectiveSize }
        return backend.kind == .novelAI ? "832x1216" : "1024x1024"
    }

    func backendLabel() async -> String {
        guard let backend = try? await resolveBackend() else { return "未配置" }
        return backend.label
    }

    func generate(
        bookId: Int64,
        chapterIndex: Int?,
        charOffset: Int?,
        sourceText: String,
        recipe: ImageRecipe,
        personaId: Int64? = nil,
        persist: Bool = true
    ) async throws -> GeneratedIllustration {
        if let chapterIndex {
            guard let book = try await LibraryRepository.shared.book(id: bookId), chapterIndex <= book.maxReachedChapterIndex else {
                throw ImageGenerationError.unsupported("当前已读范围不包含这张插图")
            }
            guard recipe.cast.allSatisfy({ $0.sinceChapter <= chapterIndex }) else {
                throw ImageGenerationError.unsupported("配方含后续章节的人物形象")
            }
        }
        let backend = try await resolveBackend()
        let caps = await capabilities()
        guard recipe.cast.count <= caps.maxCharacters else { throw ImageGenerationError.unsupported("当前模型支持的出场人物数量不足") }
        guard recipe.references.count <= caps.maxReferences else { throw ImageGenerationError.unsupported("参考图数量超过当前模型上限") }
        let assembled = ImageRecipeLogic.assemble(recipe, capabilities: caps)
        let bytes = try await request(backend: backend, recipe: recipe, prompt: assembled.prompt, negative: assembled.negative, characterPrompts: recipe.cast.map { caps.tags ? ($0.tags.isEmpty ? $0.natural : $0.tags) : $0.natural })
        guard bytes.count <= 30 * 1024 * 1024, let image = UIImage(data: bytes) else { throw ImageGenerationError.invalidResponse("生图接口返回的不是有效图片") }
        let root = try MoReadDatabase.applicationDirectory().appendingPathComponent("illustrations", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ext = bytes.starts(with: [0x89,0x50,0x4e,0x47]) ? "png" : "jpg"
        let url = root.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try bytes.write(to: url, options: .atomic)
        let rawRecipe = (try? ImageRecipeLogic.encode(recipe)) ?? ""
        let cast = String(data: try JSONSerialization.data(withJSONObject: recipe.cast.map(\.characterKey)), encoding: .utf8) ?? "[]"
        var item = GeneratedIllustration(
            bookId: bookId, chapterIndex: chapterIndex, charOffset: charOffset, sourceText: sourceText,
            prompt: assembled.prompt, imagePath: url.path, mediaType: ext == "png" ? "image/png" : "image/jpeg",
            pixelWidth: Int(image.size.width * image.scale), pixelHeight: Int(image.size.height * image.scale), personaId: personaId,
            recipeJSON: rawRecipe, castKeysJSON: cast, createdAt: Self.now()
        )
        if persist { item.id = try await insert(item) }
        return item
    }

    func illustrations(bookId: Int64) async throws -> [GeneratedIllustration] {
        try await db.rows("SELECT * FROM illustrations WHERE bookId=? ORDER BY createdAt DESC", [.integer(bookId)]).compactMap(Self.row)
    }
    func illustration(id: Int64) async throws -> GeneratedIllustration? {
        try await db.rows("SELECT * FROM illustrations WHERE id=? LIMIT 1", [.integer(id)]).first.flatMap(Self.row)
    }
    func delete(id: Int64) async throws {
        if let path = try await db.rows("SELECT imagePath FROM illustrations WHERE id=?", [.integer(id)]).first?["imagePath"]?.string { try? FileManager.default.removeItem(atPath: path) }
        try await db.execute("DELETE FROM illustrations WHERE id=?", [.integer(id)])
    }
    @discardableResult func insert(_ item: GeneratedIllustration) async throws -> Int64 {
        try await db.execute(
            "INSERT INTO illustrations(bookId,chapterIndex,charOffset,sourceText,prompt,imagePath,mediaType,pixelWidth,pixelHeight,createdByPersonaId,recipeJson,castKeys,textAnchorJson,createdAt) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [.integer(item.bookId), item.chapterIndex.map { .integer(Int64($0)) } ?? .null, item.charOffset.map { .integer(Int64($0)) } ?? .null,
             .text(item.sourceText), .text(item.prompt), .text(item.imagePath), item.mediaType.map(SQLValue.text) ?? .null,
             .integer(Int64(item.pixelWidth)), .integer(Int64(item.pixelHeight)), item.personaId.map(SQLValue.integer) ?? .null,
             .text(item.recipeJSON), .text(item.castKeysJSON), .text(""), .integer(item.createdAt)]
        )
    }

    private func resolveBackend() async throws -> Backend {
        let standalone = await MainActor.run { (ImageAPISettingsStore.shared.settings, ImageAPISettingsStore.shared.apiKey) }
        if standalone.0.configured {
            guard !standalone.1.isEmpty else { throw ImageGenerationError.unsupported("独立生图服务缺少 API Key") }
            let base: String
            do { base = try NetworkEndpointPolicy.normalizedServiceBaseURL(standalone.0.baseURL) }
            catch { throw ImageGenerationError.unsupported(error.localizedDescription) }
            return .init(kind: standalone.0.provider, label: "\(standalone.0.provider.label) · \(standalone.0.model)", baseURL: base, model: standalone.0.model, endpoint: "", apiKey: standalone.1, extraBody: [:], extraHeaders: [:], settings: standalone.0)
        }
        let (provider, model) = try await AIProviderRepository.shared.resolve(.image)
        let key = await AIProviderRepository.shared.apiKey(for: provider)
        guard !key.isEmpty else { throw ImageGenerationError.unsupported("生图服务缺少 API Key") }
        let endpoint = model.endpointPath
        let kind: ImageAPIProvider = endpoint.localizedCaseInsensitiveContains("chat/completion") ? .openAIChat : .openAIImages
        let p = RequestOverrides.parse(provider.extraJSON), m = RequestOverrides.parse(model.extraJSON)
        var body = p.body.mapValues(AnySendable.init); m.body.forEach { body[$0.key] = AnySendable($0.value) }
        var headers = p.headers; m.headers.forEach { headers[$0.key] = $0.value }
        let base: String
        do { base = try NetworkEndpointPolicy.normalizedServiceBaseURL(provider.baseURL) }
        catch { throw ImageGenerationError.unsupported(error.localizedDescription) }
        return .init(kind: kind, label: model.modelName, baseURL: base, model: model.modelName, endpoint: endpoint, apiKey: key, extraBody: body, extraHeaders: headers, settings: nil)
    }

    private func request(backend: Backend, recipe: ImageRecipe, prompt: String, negative: String, characterPrompts: [String]) async throws -> Data {
        switch backend.kind {
        case .openAIImages: return try await requestOpenAIImages(backend, recipe: recipe, prompt: prompt)
        case .openAIChat: return try await requestChatImage(backend, recipe: recipe, prompt: prompt)
        case .novelAI: return try await requestNovelAI(backend, recipe: recipe, prompt: prompt, negative: negative, characterPrompts: characterPrompts)
        }
    }

    private func referenceData(_ refs: [ReferenceSpec]) async throws -> [(ReferenceSpec, Data)] {
        try await refs.asyncMap { ref in (ref, try await ImageAssetLibrary.shared.normalizedData(id: ref.assetId, preciseCharacter: ref.kind == .character)) }
    }

    private func requestOpenAIImages(_ backend: Backend, recipe: ImageRecipe, prompt: String) async throws -> Data {
        let refs = try await referenceData(recipe.references)
        if !refs.isEmpty {
            let endpoint = backend.endpoint.isEmpty ? "/images/edits" : backend.endpoint.replacingOccurrences(of: "/generations", with: "/edits")
            guard let url = URL(string: backend.baseURL + endpoint) else { throw ImageGenerationError.invalidResponse("生图地址无效") }
            let boundary = "MoRead-\(UUID().uuidString)"; var body = Data()
            func field(_ name: String, _ value: String) { body.appendMultipart(boundary: boundary, name: name, value: value) }
            field("model", backend.model); field("prompt", prompt); field("n", "1"); field("size", recipe.size ?? backend.settings?.effectiveSize ?? "1024x1024")
            for (index, pair) in refs.enumerated() { body.appendMultipart(boundary: boundary, name: "image[]", filename: "reference-\(index).jpg", mime: "image/jpeg", data: pair.1) }
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            var req = URLRequest(url: url); req.httpMethod = "POST"; req.setValue("Bearer \(backend.apiKey)", forHTTPHeaderField: "Authorization"); req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"); req.httpBody = body
            backend.extraHeaders.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
            let responseData = try await dataRequest(req); return try await parseOpenAIImageResponse(responseData)
        }
        let endpoint = backend.endpoint.isEmpty ? "/images/generations" : backend.endpoint
        guard let url = URL(string: backend.baseURL + endpoint) else { throw ImageGenerationError.invalidResponse("生图地址无效") }
        var body: [String: Any] = ["model": backend.model, "prompt": prompt, "n": 1, "response_format": "b64_json", "size": recipe.size ?? backend.settings?.effectiveSize ?? "1024x1024"]
        backend.extraBody.forEach { body[$0.key] = $0.value.value }; if let seed = recipe.seed { body["seed"] = seed }
        var req=URLRequest(url:url);req.httpMethod="POST";req.setValue("Bearer \(backend.apiKey)",forHTTPHeaderField:"Authorization");req.setValue("application/json",forHTTPHeaderField:"Content-Type");backend.extraHeaders.forEach{req.setValue($0.value,forHTTPHeaderField:$0.key)};req.httpBody=try JSONSerialization.data(withJSONObject:body)
        let responseData = try await dataRequest(req); return try await parseOpenAIImageResponse(responseData)
    }

    private func requestChatImage(_ backend: Backend, recipe: ImageRecipe, prompt: String) async throws -> Data {
        let endpoint = backend.endpoint.isEmpty ? "/chat/completions" : backend.endpoint
        guard let url = URL(string: backend.baseURL + endpoint) else { throw ImageGenerationError.invalidResponse("Chat 生图地址无效") }
        var content: [[String: Any]] = [["type":"text","text": prompt + (recipe.size.map { "\nCanvas: \($0)." } ?? "")]]
        for (_, data) in try await referenceData(recipe.references) { content.append(["type":"image_url","image_url":["url":"data:image/jpeg;base64,\(data.base64EncodedString())"]]) }
        var body: [String: Any] = ["model":backend.model,"messages":[["role":"user","content":content]],"stream":false,"modalities":["image","text"]]
        backend.extraBody.forEach { body[$0.key] = $0.value.value }
        var req=URLRequest(url:url);req.httpMethod="POST";req.setValue("Bearer \(backend.apiKey)",forHTTPHeaderField:"Authorization");req.setValue("application/json",forHTTPHeaderField:"Content-Type");backend.extraHeaders.forEach{req.setValue($0.value,forHTTPHeaderField:$0.key)};req.httpBody=try JSONSerialization.data(withJSONObject:body)
        let data = try await dataRequest(req)
        if let ref = Self.findImageReference(in: try JSONSerialization.jsonObject(with: data)) { return try await materialize(ref, backend: backend) }
        let raw=String(data:data,encoding:.utf8) ?? "";if let match=raw.range(of:#"https?://[^\s\)\]\"']+"#,options:.regularExpression){return try await materialize(String(raw[match]),backend:backend)}
        throw ImageGenerationError.invalidResponse("Chat 响应中没有图片")
    }

    private func requestNovelAI(_ backend: Backend, recipe: ImageRecipe, prompt: String, negative: String, characterPrompts: [String]) async throws -> Data {
        let settings = backend.settings ?? .init(provider: .novelAI, baseURL: backend.baseURL, model: backend.model)
        let (width,height)=Self.novelSize(recipe.size ?? settings.effectiveSize)
        var params:[String:Any]=["width":width,"height":height,"scale":min(10,max(0,settings.scale)),"sampler":settings.sampler.isEmpty ? "k_euler_ancestral":settings.sampler,"steps":min(50,max(1,settings.steps)),"n_samples":1,"ucPreset":0,"qualityToggle":true,"negative_prompt":[settings.negativePrompt,negative].filter{!$0.isEmpty}.joined(separator:", ")]
        if let seed=recipe.seed{params["seed"]=seed & 0xffff_ffff}
        let refs=try await referenceData(recipe.references);let charRefs=refs.filter{$0.0.kind == .character};let styleRefs=refs.filter{$0.0.kind == .style};guard charRefs.isEmpty || styleRefs.isEmpty else{throw ImageGenerationError.unsupported("NovelAI 角色参考不能与 Vibe 同时使用")}
        if !charRefs.isEmpty { params["director_reference_images"]=charRefs.map{$0.1.base64EncodedString()};params["director_reference_descriptions"]=charRefs.map{_ in ["caption":["base_caption":"character","char_captions":[]]]};params["director_reference_information_extracted"]=charRefs.map{_ in 1.0};params["director_reference_strength_values"]=charRefs.map{$0.0.strength};params["director_reference_secondary_strength_values"]=charRefs.map{$0.0.fidelity} }
        if !styleRefs.isEmpty { var vibes:[String]=[];for pair in styleRefs{vibes.append(try await encodedVibe(backend:backend,data:pair.1,information:pair.0.informationExtracted))};params["reference_image_multiple"]=vibes;params["reference_information_extracted_multiple"]=styleRefs.map{_ in 1.0};let total=max(1,styleRefs.reduce(0.0){$0+$1.0.strength});params["reference_strength_multiple"]=styleRefs.map{$0.0.strength/total} }
        let isV4=backend.model.hasPrefix("nai-diffusion-4") || backend.model.hasPrefix("nai-diffusion-5")
        let effective=[settings.positivePrompt,prompt].filter{!$0.isEmpty}.joined(separator:", ")
        if isV4 { params["params_version"]=3;params["v4_prompt"]=["caption":["base_caption":effective,"char_captions":characterPrompts.map{["char_caption":$0,"centers":[]]}],"use_coords":false,"use_order":true];params["v4_negative_prompt"]=["caption":["base_caption":params["negative_prompt"] as? String ?? "","char_captions":[]]] }
        guard let url=URL(string:backend.baseURL+"/ai/generate-image") else{throw ImageGenerationError.invalidResponse("NovelAI 地址无效")};let body:[String:Any]=["input":effective,"model":backend.model,"action":"generate","parameters":params];var req=URLRequest(url:url);req.httpMethod="POST";req.setValue("Bearer \(backend.apiKey)",forHTTPHeaderField:"Authorization");req.httpBody=try JSONSerialization.data(withJSONObject:body);req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let zip=try await dataRequest(req,limit:30*1024*1024);return try Self.firstImageFromZIP(zip)
    }

    private func encodedVibe(backend:Backend,data:Data,information:Double)async throws->String{let hash=data.sha256Hex+"-\(backend.model)-\(information)";let root=try MoReadDatabase.applicationDirectory().appendingPathComponent("image-vibes",isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);let file=root.appendingPathComponent(hash+".bin");if let cached=try? Data(contentsOf:file),!cached.isEmpty{return cached.base64EncodedString()};guard let url=URL(string:backend.baseURL+"/ai/encode-vibe") else{throw ImageGenerationError.invalidResponse("Vibe 地址无效")};let body:[String:Any]=["model":backend.model,"image":data.base64EncodedString(),"information_extracted":min(1,max(0,information))];var req=URLRequest(url:url);req.httpMethod="POST";req.setValue("Bearer \(backend.apiKey)",forHTTPHeaderField:"Authorization");req.setValue("application/json",forHTTPHeaderField:"Content-Type");req.httpBody=try JSONSerialization.data(withJSONObject:body);let encoded=try await dataRequest(req);try encoded.write(to:file,options:.atomic);return encoded.base64EncodedString()}

    private func parseOpenAIImageResponse(_ data: Data) async throws -> Data { guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],let first=(root["data"] as? [[String:Any]])?.first else{throw ImageGenerationError.invalidResponse(String(data:data,encoding:.utf8) ?? "生图响应缺少 data")};if let b64=first["b64_json"] as? String,let out=Data(base64Encoded:b64){return out};if let url=first["url"] as? String{return try await materialize(url,backend:nil)};throw ImageGenerationError.invalidResponse("生图响应缺少图片") }
    private func materialize(_ ref:String,backend:Backend?)async throws->Data{if ref.lowercased().hasPrefix("data:image"),let comma=ref.firstIndex(of:","),let d=Data(base64Encoded:String(ref[ref.index(after:comma)...])){return d};guard let url=URL(string:ref),url.scheme=="https" || (url.scheme=="http" && ["127.0.0.1","localhost"].contains(url.host ?? "")) else{throw ImageGenerationError.invalidResponse("图片地址不安全")};var req=URLRequest(url:url);if let backend,URL(string:backend.baseURL)?.host==url.host{req.setValue("Bearer \(backend.apiKey)",forHTTPHeaderField:"Authorization")};return try await dataRequest(req)}
    private func dataRequest(_ req:URLRequest,limit:Int=42*1024*1024)async throws->Data{let started=Date();do{let(data,response)=try await URLSession.shared.data(for:req);let http=response as? HTTPURLResponse;await APICallLogger.record(request:req,startedAt:started,response:http,responseBytes:data.count,category:"Image");guard let http,(200..<300).contains(http.statusCode) else{throw ImageGenerationError.invalidResponse(String(data:data,encoding:.utf8) ?? "生图请求失败")};guard data.count<=limit else{throw ImageGenerationError.invalidResponse("生图响应超过大小限制")};return data}catch{await APICallLogger.record(request:req,startedAt:started,response:nil,responseBytes:0,category:"Image",error:error);throw error}}

    private static func firstImageFromZIP(_ data:Data)throws->Data{let root=FileManager.default.temporaryDirectory.appendingPathComponent("moread-nai-\(UUID().uuidString).zip");try data.write(to:root);defer{try? FileManager.default.removeItem(at:root)};guard let archive=Archive(url:root,accessMode:.read) else{throw ImageGenerationError.invalidResponse("NovelAI 返回的不是有效 ZIP")};for entry in archive where ["png","jpg","jpeg","webp"].contains(URL(fileURLWithPath:entry.path).pathExtension.lowercased()){guard entry.uncompressedSize<=30*1024*1024 else{throw ImageGenerationError.invalidResponse("NovelAI 图片超过 30 MB")};var out=Data();_ = try archive.extract(entry){chunk in if out.count+chunk.count<=30*1024*1024{out.append(chunk)}};if !out.isEmpty{return out}};throw ImageGenerationError.invalidResponse("NovelAI ZIP 中没有图片")}
    private static func novelSize(_ raw:String)->(Int,Int){let p=raw.lowercased().replacingOccurrences(of:"×",with:"x").split(separator:"x");let w=Int(p.first ?? "") ?? 832,h=Int(p.dropFirst().first ?? "") ?? 1216;func a(_ x:Int)->Int{min(2048,max(64,x/64*64))};return(a(w),a(h))}
    private static func findImageReference(in value:Any)->String?{if let s=value as? String,(s.hasPrefix("data:image") || s.hasPrefix("https://") || s.hasPrefix("http://")){return s};if let a=value as? [Any]{for v in a{if let x=findImageReference(in:v){return x}}};if let d=value as? [String:Any]{for v in d.values{if let x=findImageReference(in:v){return x}}};return nil}
    private static func row(_ r: [String: SQLValue]) -> GeneratedIllustration? {
        guard let id = r["id"]?.int64, let bookId = r["bookId"]?.int64 else { return nil }
        let chapterIndex: Int? = r["chapterIndex"]?.int64.map(Int.init)
        let charOffset: Int? = r["charOffset"]?.int64.map(Int.init)
        let sourceText: String = r["sourceText"]?.string ?? ""
        let prompt: String = r["prompt"]?.string ?? ""
        let imagePath: String = r["imagePath"]?.string ?? ""
        let mediaType: String? = r["mediaType"]?.string
        let width: Int = Int(r["pixelWidth"]?.int64 ?? 0)
        let height: Int = Int(r["pixelHeight"]?.int64 ?? 0)
        let personaId: Int64? = r["createdByPersonaId"]?.int64
        let recipeJSON: String = r["recipeJson"]?.string ?? ""
        let castKeysJSON: String = r["castKeys"]?.string ?? "[]"
        let createdAt: Int64 = r["createdAt"]?.int64 ?? 0
        return GeneratedIllustration(id: id, bookId: bookId, chapterIndex: chapterIndex, charOffset: charOffset,
                                     sourceText: sourceText, prompt: prompt, imagePath: imagePath, mediaType: mediaType,
                                     pixelWidth: width, pixelHeight: height, personaId: personaId,
                                     recipeJSON: recipeJSON, castKeysJSON: castKeysJSON, createdAt: createdAt)
    }
    private static func now()->Int64{Int64(Date().timeIntervalSince1970*1000)}
}

private struct AnySendable: @unchecked Sendable { let value: Any; init(_ value:Any){self.value=value} }
private extension Array { func asyncMap<T>(_ transform:(Element) async throws->T) async rethrows->[T]{var out:[T]=[];out.reserveCapacity(count);for x in self{out.append(try await transform(x))};return out} }
private extension Data {
    mutating func appendMultipart(boundary:String,name:String,value:String){append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using:.utf8)!)}
    mutating func appendMultipart(boundary:String,name:String,filename:String,mime:String,data:Data){append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using:.utf8)!);append(data);append("\r\n".data(using:.utf8)!)}
    var sha256Hex:String{SHA256.hash(data:self).map { String(format: "%02x", $0) }.joined()}
}
