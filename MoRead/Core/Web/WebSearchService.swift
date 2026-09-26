import Foundation

struct WebSearchResult: Codable, Hashable, Sendable { var title:String; var url:String; var snippet:String }
struct WebScrapeResult: Codable, Hashable, Sendable { var title:String; var url:String; var content:String }

enum WebSearchProvider: String, Codable, CaseIterable, Sendable {
    case firecrawl, exa, tavily
    var label:String { switch self { case .firecrawl:"Firecrawl"; case .exa:"Exa"; case .tavily:"Tavily" } }
    var defaultSearchEndpoint:String { switch self { case .firecrawl:"https://api.firecrawl.dev/v2/search"; case .exa:"https://api.exa.ai/search"; case .tavily:"https://api.tavily.com/search" } }
    var defaultScrapeEndpoint:String { switch self { case .firecrawl:"https://api.firecrawl.dev/v2/scrape"; case .exa:"https://api.exa.ai/contents"; case .tavily:"https://api.tavily.com/extract" } }
}

struct WebSearchSettings: Codable, Equatable, Sendable {
    var enabled=false
    var provider:WebSearchProvider = .firecrawl
    var searchEndpoints:[WebSearchProvider:String] = [:]
    var scrapeEndpoints:[WebSearchProvider:String] = [:]
    func searchEndpoint()->String { searchEndpoints[provider]?.nilIfEmpty ?? provider.defaultSearchEndpoint }
    func scrapeEndpoint()->String { scrapeEndpoints[provider]?.nilIfEmpty ?? provider.defaultScrapeEndpoint }
}

@MainActor final class WebSearchSettingsStore:ObservableObject {
    static let shared=WebSearchSettingsStore()
    @Published var settings:WebSearchSettings { didSet { save() } }
    @Published var apiKey:String="" { didSet { if !loading { KeychainStore.set(apiKey, account: keyAlias(settings.provider)) } } }
    private var loading=true
    private let url:URL
    init(){let root=(try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory;url=root.appendingPathComponent("web-search-settings.json");if let d=try? Data(contentsOf:url),let v=try? JSONDecoder().decode(WebSearchSettings.self,from:d){settings=v}else{settings = .init()};apiKey=KeychainStore.get(account: keyAlias(settings.provider));loading=false}
    func switchProvider(_ value:WebSearchProvider){loading=true;settings.provider=value;apiKey=KeychainStore.get(account: keyAlias(value));loading=false;save()}
    func configured()->Bool { settings.enabled && !apiKey.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    private func save(){try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);if let d=try? JSONEncoder().encode(settings){try? d.write(to:url,options:.atomic)}}
    private func keyAlias(_ p:WebSearchProvider)->String{"web-search-\(p.rawValue)-api-key"}
}

actor WebSearchService {
    static let shared=WebSearchService()
    private let session:URLSession
    init(){let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=30;c.timeoutIntervalForResource=45;c.httpMaximumConnectionsPerHost=4;session=URLSession(configuration:c)}

    func search(_ query:String,limit:Int=5) async throws->[WebSearchResult]{
        let config=await MainActor.run{(WebSearchSettingsStore.shared.settings,WebSearchSettingsStore.shared.apiKey)}
        let settings=config.0,key=config.1.trimmingCharacters(in:.whitespacesAndNewlines);guard settings.enabled else{throw WebSearchError.message("网络搜索尚未启用")};guard !key.isEmpty else{throw WebSearchError.message("\(settings.provider.label) API Key 尚未配置")}
        let cap=min(8,max(1,limit));let payload:[String:Any]=switch settings.provider{case .firecrawl:["query":query,"limit":cap];case .exa:["query":query,"numResults":cap,"type":"auto","contents":["text":["maxCharacters":1200]]];case .tavily:["query":query,"max_results":cap,"search_depth":"advanced","include_answer":false,"include_raw_content":false]}
        let root=try await request(url:settings.searchEndpoint(),provider:settings.provider,key:key,payload:payload)
        return parseSearch(root,provider:settings.provider).prefix(cap).map{$0}
    }

    func scrape(_ rawURL:String) async throws->WebScrapeResult{
        let config=await MainActor.run{(WebSearchSettingsStore.shared.settings,WebSearchSettingsStore.shared.apiKey)};let settings=config.0,key=config.1.trimmingCharacters(in:.whitespacesAndNewlines)
        guard settings.enabled,!key.isEmpty else{throw WebSearchError.message("网络搜索尚未配置")};guard let url=URL(string:rawURL),["http","https"].contains(url.scheme?.lowercased() ?? "") else{throw WebSearchError.message("网页地址无效")}
        let payload:[String:Any]=switch settings.provider{case .firecrawl:["url":rawURL,"formats":["markdown"],"onlyMainContent":true];case .exa:["urls":[rawURL],"text":true];case .tavily:["urls":rawURL,"extract_depth":"advanced","format":"markdown","include_images":false]}
        let root=try await request(url:settings.scrapeEndpoint(),provider:settings.provider,key:key,payload:payload)
        return try parseScrape(root,provider:settings.provider,requestedURL:rawURL)
    }

    private func request(url:String,provider:WebSearchProvider,key:String,payload:[String:Any]) async throws->[String:Any]{
        guard let endpoint=URL(string:url),["https"].contains(endpoint.scheme?.lowercased() ?? "") else{throw WebSearchError.message("搜索接口必须使用 HTTPS")}
        var req=URLRequest(url:endpoint);req.httpMethod="POST";req.setValue("application/json", forHTTPHeaderField: "Content-Type");req.setValue("application/json", forHTTPHeaderField: "Accept");switch provider{case .firecrawl,.tavily:req.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization");case .exa:req.setValue(key,forHTTPHeaderField:"x-api-key")};req.httpBody=try JSONSerialization.data(withJSONObject:payload)
        let started=Date()
        do {
            let (data,response)=try await session.data(for:req);let http=response as? HTTPURLResponse
            await APICallLogger.record(request:req,startedAt:started,response:http,responseBytes:data.count,category:"WebSearch")
            guard let http else{throw WebSearchError.message("搜索服务没有返回 HTTP 响应")};guard (200..<300).contains(http.statusCode) else{throw WebSearchError.message("\(provider.label) 请求失败（HTTP \(http.statusCode)）")};guard data.count<=4*1024*1024,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw WebSearchError.message("搜索响应无法解析")};return root
        } catch { await APICallLogger.record(request:req,startedAt:started,response:nil,responseBytes:0,category:"WebSearch",error:error); throw error }
    }

    private func parseSearch(_ root:[String:Any],provider:WebSearchProvider)->[WebSearchResult]{
        let rows:[[String:Any]]=switch provider{case .firecrawl: (root["data"] as? [[String:Any]]) ?? ((root["data"] as? [String:Any])?["web"] as? [[String:Any]]) ?? (root["results"] as? [[String:Any]]) ?? [];case .exa,.tavily:root["results"] as? [[String:Any]] ?? []}
        var seen=Set<String>();return rows.compactMap{r in guard let u=(r["url"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines),URL(string:u) != nil,seen.insert(u).inserted else{return nil};let title=(r["title"] as? String)?.nilIfEmpty ?? u;let keys=provider == .firecrawl ? ["description","snippet","markdown"]:(provider == .exa ? ["text","summary","snippet"]:["content","snippet","raw_content"]);let snippet=keys.compactMap{r[$0] as? String}.first?.replacingOccurrences(of:"\\s+",with:" ",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines) ?? "";return .init(title:String(title.prefix(240)),url:u,snippet:String(snippet.prefix(1200)))}
    }

    private func parseScrape(_ root:[String:Any],provider:WebSearchProvider,requestedURL:String)throws->WebScrapeResult{
        let item:[String:Any]=switch provider{case .firecrawl:root["data"] as? [String:Any] ?? [:];case .exa,.tavily:(root["results"] as? [[String:Any]])?.first ?? [:]};let meta=item["metadata"] as? [String:Any] ?? [:];let url=(item["url"] as? String) ?? (meta["sourceURL"] as? String) ?? requestedURL;let title=(item["title"] as? String) ?? (meta["title"] as? String) ?? url;let keys=provider == .firecrawl ? ["markdown","content","html"]:(provider == .exa ? ["text","summary","content"]:["raw_content","content"]);guard let content=keys.compactMap({item[$0] as? String}).first?.trimmingCharacters(in:.whitespacesAndNewlines),!content.isEmpty else{throw WebSearchError.message("返回结果中没有可用网页正文")};return .init(title:String(title.prefix(240)),url:url,content:String(content.prefix(20_000)))
    }
}

enum WebSearchError:LocalizedError{case message(String);var errorDescription:String?{switch self{case .message(let s):s}}}
private extension String{var nilIfEmpty:String?{let x=trimmingCharacters(in:.whitespacesAndNewlines);return x.isEmpty ? nil:x}}

struct WebImageSearchResult: Codable, Hashable, Sendable {
    var title: String
    var imageURL: String
    var pageURL: String
    var source: String
    var width: Int? = nil
    var height: Int? = nil
}

extension WebSearchService {
    func searchImages(_ query: String, limit: Int = 12) async throws -> [WebImageSearchResult] {
        let config = await MainActor.run { (WebSearchSettingsStore.shared.settings, WebSearchSettingsStore.shared.apiKey) }
        let settings = config.0, key = config.1.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.enabled else { throw WebSearchError.message("网络搜索尚未启用") }
        guard !key.isEmpty else { throw WebSearchError.message("\(settings.provider.label) API Key 尚未配置") }
        let cap = min(30, max(1, limit))
        let payload: [String: Any] = switch settings.provider {
        case .firecrawl: ["query": query, "limit": cap, "sources": [["type": "images"]]]
        case .exa: ["query": query, "numResults": cap, "type": "auto", "contents": ["text": false, "extras": ["imageLinks": 5]]]
        case .tavily: ["query": query, "max_results": cap, "search_depth": "advanced", "include_answer": false, "include_raw_content": false, "include_images": true, "include_image_descriptions": true]
        }
        let root = try await request(url: settings.searchEndpoint(), provider: settings.provider, key: key, payload: payload)
        return parseImages(root, provider: settings.provider).prefix(cap).map { $0 }
    }

    private func parseImages(_ root: [String: Any], provider: WebSearchProvider) -> [WebImageSearchResult] {
        var result: [WebImageSearchResult] = []
        func add(_ raw: Any?, page: String?, title: String?) {
            if let text = raw as? String { addURL(text, page: page, title: title); return }
            guard let row = raw as? [String: Any] else { return }
            let image = ["imageUrl", "url", "image"].compactMap { row[$0] as? String }.first
            addURL(image, page: page ?? row["pageUrl"] as? String ?? row["url"] as? String,
                   title: (row["title"] as? String) ?? (row["description"] as? String) ?? title,
                   width: row["imageWidth"] as? Int ?? row["width"] as? Int,
                   height: row["imageHeight"] as? Int ?? row["height"] as? Int)
        }
        func addURL(_ raw: String?, page: String?, title: String?, width: Int? = nil, height: Int? = nil) {
            guard let raw, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            let p = page.flatMap(URL.init(string:)) != nil ? page! : raw
            result.append(.init(title: String((title?.nilIfEmpty ?? p).prefix(240)), imageURL: raw, pageURL: p,
                                source: provider.label, width: width, height: height))
        }
        switch provider {
        case .firecrawl:
            let data = root["data"] as? [String: Any]
            let images = (data?["images"] as? [Any]) ?? (root["images"] as? [Any]) ?? []
            images.forEach { add($0, page: nil, title: nil) }
        case .exa:
            for row in root["results"] as? [[String: Any]] ?? [] {
                let page = (row["url"] as? String) ?? (row["id"] as? String), title = row["title"] as? String
                add(row["image"], page: page, title: title)
                if let extras = row["extras"] as? [String: Any] { (extras["imageLinks"] as? [Any] ?? []).forEach { add($0, page: page, title: title) } }
                (row["imageLinks"] as? [Any] ?? []).forEach { add($0, page: page, title: title) }
            }
        case .tavily:
            (root["images"] as? [Any] ?? []).forEach { add($0, page: nil, title: nil) }
            for row in root["results"] as? [[String: Any]] ?? [] {
                let page = row["url"] as? String, title = row["title"] as? String
                (row["images"] as? [Any] ?? []).forEach { add($0, page: page, title: title) }
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.imageURL).inserted }
    }
}
