import Foundation

struct OnlineBookCover: Identifiable, Hashable, Sendable {
    var id: String { imageURL }
    var title: String
    var author: String
    var imageURL: String
    var source: String
}

struct OnlineBookCoverSearchResult: Sendable {
    var covers: [OnlineBookCover]
    var queries: [String]
    var agentEnhanced: Bool
}

actor BookCoverService {
    static let shared = BookCoverService()
    private let session: URLSession
    private var cache: [String: (Date, OnlineBookCoverSearchResult)] = [:]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 45
        session = URLSession(configuration: config)
    }

    func search(book: Book) async throws -> OnlineBookCoverSearchResult {
        let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw BookCoverError.message("请先填写书名") }
        let configured = await MainActor.run { WebSearchSettingsStore.shared.configured() }
        let cacheKey = "\(title.lowercased())::\(author.lowercased())::\(configured)"
        if let cached = cache[cacheKey], Date().timeIntervalSince(cached.0) < 600 { return cached.1 }

        let agentQueries = (try? await coverSearchQueries(title: title, author: author)) ?? []
        let fallback = ["\"\(title)\"", author.isEmpty ? nil : "\"\(author)\"", "书籍封面 book cover"].compactMap { $0 }.joined(separator: " ")
        let queries = Array((agentQueries + [fallback]).filter { !$0.isEmpty }.reduce(into: [String]()) { values, item in
            if !values.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) { values.append(item) }
        }.prefix(3))

        var covers: [OnlineBookCover] = []
        if configured {
            for query in queries {
                if let rows = try? await WebSearchService.shared.searchImages(query, limit: 12) {
                    covers += rows.map { .init(title: $0.title.isEmpty ? title : $0.title, author: author, imageURL: $0.imageURL, source: $0.source) }
                }
                if Set(covers.map(\.imageURL)).count >= 24 { break }
            }
        }
        if covers.isEmpty { covers = (try? await openLibrary(title: title, author: author)) ?? [] }
        if covers.isEmpty, !author.isEmpty { covers = (try? await openLibrary(title: title, author: "")) ?? [] }
        if covers.isEmpty { covers = (try? await googleBooks(title: title, author: author)) ?? [] }
        var seen = Set<String>(); covers = covers.filter { seen.insert($0.imageURL).inserted }
        let result = OnlineBookCoverSearchResult(covers: covers, queries: queries, agentEnhanced: !agentQueries.isEmpty)
        cache[cacheKey] = (Date(), result)
        return result
    }

    func download(_ cover: OnlineBookCover) async throws -> URL {
        guard let url = URL(string: cover.imageURL), ["http","https"].contains(url.scheme?.lowercased() ?? "") else { throw BookCoverError.message("封面地址无效") }
        var request = URLRequest(url: url); request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw BookCoverError.message("封面下载失败") }
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024 else { throw BookCoverError.message("封面图片为空或超过 25 MB") }
        let ext = Self.extensionFor(data: data, mime: http.value(forHTTPHeaderField: "Content-Type"))
        let urlOut = FileManager.default.temporaryDirectory.appendingPathComponent("moread-cover-\(UUID().uuidString).\(ext)")
        try data.write(to: urlOut, options: .atomic)
        return urlOut
    }

    func generate(book: Book, customPrompt: String = "") async throws -> URL {
        let chapters = try await LibraryRepository.shared.chapters(bookId: book.id)
        let first = chapters.first
        let excerpt: String
        if let first { excerpt = try await LibraryRepository.shared.chapterText(first) } else { excerpt = "" }
        let direction: String
        if !customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { direction = String(customPrompt.prefix(8_000)) }
        else { direction = (try? await coverPrompt(title: book.title, author: book.author, excerpt: String(excerpt.prefix(1_200)))) ?? "精致、克制、有文学感，以一个最具辨识度的核心意象作为主体。" }
        let scene = """
        为小说《\(book.title)》创作竖版 2:3 书籍封面主视觉。\n\(direction)\n构图适合缩略图，主体清晰，保留安全边距；不要生成文字、水印、边框或出版社标识。开篇参考：\(String(excerpt.prefix(1_200)))
        """
        let chapterIndex = min(max(0, first?.chapterIndex ?? 0), max(0, book.maxReachedChapterIndex))
        var recipe = try await ImageConsistencyRepository.shared.plan(bookId: book.id, chapterIndex: chapterIndex, source: scene, useReferences: true, size: "1024x1536")
        recipe.shot.action = scene
        let defaultSize = await ImageGenerationService.shared.defaultSize()
        if defaultSize.contains("x") { recipe.size = "1024x1536" }
        let generated = try await ImageGenerationService.shared.generate(bookId: book.id, chapterIndex: chapterIndex, charOffset: nil, sourceText: "", recipe: recipe, persist: false)
        return URL(fileURLWithPath: generated.imagePath)
    }

    private func coverSearchQueries(title: String, author: String) async throws -> [String] {
        let client = try await AIClientFactory.forRole(.cheap)
        let prompt = """
        为书籍《\(title)》（\(author.isEmpty ? "未知作者" : author)）生成 2 到 3 行封面图片搜索词。每行必须包含作品名或可靠别名，并包含作者（已知时）以及“书籍封面”或“book cover”。只输出搜索词，不编号、不解释。
        """
        let raw = try await client.client.chat(messages: [.init(role: .user, content: prompt)], options: client.options)
        return raw.replacingOccurrences(of: "```", with: "").split(separator: "\n").map {
            String($0).replacingOccurrences(of: #"^\s*(?:[-*•]|\d+[.)、])\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }.filter { $0.count >= 6 && $0.count <= 240 && ($0.localizedCaseInsensitiveContains("cover") || $0.contains("封面")) }.prefix(3).map { $0 }
    }

    private func coverPrompt(title: String, author: String, excerpt: String) async throws -> String {
        let client = try await AIClientFactory.forRole(.cheap)
        let prompt = """
        你是书籍封面艺术总监。为《\(title)》（\(author.isEmpty ? "未知作者" : author)）提炼一段中文生图提示词，只输出提示词。包含主体、环境、构图、色彩、光线、媒介风格；不要剧透，不要文字。开篇摘要：\(excerpt)
        """
        return String((try await client.client.chat(messages: [.init(role: .user, content: prompt)], options: client.options)).prefix(8_000))
    }

    private func openLibrary(title: String, author: String) async throws -> [OnlineBookCover] {
        var c = URLComponents(string: "https://openlibrary.org/search.json")!
        c.queryItems = [.init(name:"title",value:title), .init(name:"limit",value:"30"), .init(name:"fields",value:"key,title,author_name,cover_i")]
        if !author.isEmpty { c.queryItems?.append(.init(name:"author",value:author)) }
        let root = try await getJSON(c.url!)
        return (root["docs"] as? [[String:Any]] ?? []).compactMap { row in
            guard let raw = row["cover_i"] as? NSNumber else { return nil }
            let t = row["title"] as? String ?? title, a = (row["author_name"] as? [String] ?? []).joined(separator:" / ")
            return .init(title:t, author:a, imageURL:"https://covers.openlibrary.org/b/id/\(raw.int64Value)-L.jpg?default=false", source:"Open Library")
        }
    }

    private func googleBooks(title: String, author: String) async throws -> [OnlineBookCover] {
        var c = URLComponents(string:"https://www.googleapis.com/books/v1/volumes")!
        let q = "intitle:\(title)" + (author.isEmpty ? "" : " inauthor:\(author)")
        c.queryItems = [.init(name:"q",value:q),.init(name:"maxResults",value:"20"),.init(name:"printType",value:"books")]
        let root = try await getJSON(c.url!)
        return (root["items"] as? [[String:Any]] ?? []).compactMap { row in
            guard let info=row["volumeInfo"] as? [String:Any], let links=info["imageLinks"] as? [String:Any] else{return nil}
            let image=["extraLarge","large","medium","small","thumbnail","smallThumbnail"].compactMap{links[$0] as? String}.first?.replacingOccurrences(of:"http://",with:"https://")
            guard let image else{return nil}
            return .init(title:info["title"] as? String ?? title, author:(info["authors"] as? [String] ?? []).joined(separator:" / "), imageURL:image, source:"Google Books")
        }
    }

    private func getJSON(_ url: URL) async throws -> [String:Any] {
        var req=URLRequest(url:url);req.setValue(Self.userAgent,forHTTPHeaderField:"User-Agent")
        let (data,response)=try await session.data(for:req);guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode),data.count<=4*1024*1024,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw BookCoverError.message("网络封面搜索失败")};return root
    }

    private static func extensionFor(data: Data, mime: String?) -> String { if mime?.localizedCaseInsensitiveContains("png")==true || data.starts(with:[0x89,0x50,0x4e,0x47]){return "png"};if mime?.localizedCaseInsensitiveContains("webp")==true{return "webp"};return "jpg" }
    private static let userAgent = "MoRead/1.2.0 (iOS book cover search)"
}

enum BookCoverError: LocalizedError { case message(String); var errorDescription: String? { switch self { case .message(let value): value } } }
