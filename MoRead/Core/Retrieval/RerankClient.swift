import Foundation

actor RerankClient {
    static let shared = RerankClient()
    func rerank(query:String,hits:[RetrievalHit],topN:Int)async throws->[RetrievalHit]{
        guard let modelId=try await AIProviderRepository.shared.assignment(.rerank),let model=try await AIProviderRepository.shared.model(id:modelId),let provider=try await AIProviderRepository.shared.provider(id:model.providerId) else{return Array(hits.prefix(topN))}
        guard case .rerank=ProviderProtocolPolicy.route(provider:provider,model:model) else{return Array(hits.prefix(topN))}
        let key=await AIProviderRepository.shared.apiKey(for:provider);guard !key.isEmpty else{throw AIClientError.unsupported("重排服务缺少 API Key")}
        let base=AIHTTP.normalizedBase(provider.baseURL);let path=model.endpointPath.isEmpty ? "/rerank":model.endpointPath;let url=try AIHTTP.endpoint(base:base,path:path)
        let body:[String:Any]=["model":model.modelName,"query":query,"documents":hits.map{$0.chunk.text},"top_n":min(max(1,topN),hits.count)]
        let request=try AIHTTP.request(url:url,headers:["Authorization":"Bearer \(key)"],json:body)
        let root=try AIHTTP.jsonObject(try await AIHTTP.data(for:request));let rows=(root["results"] as? [[String:Any]]) ?? (root["data"] as? [[String:Any]]) ?? []
        var out:[RetrievalHit]=[]
        for row in rows{let i=(row["index"] as? NSNumber)?.intValue ?? -1;guard hits.indices.contains(i) else{continue};var h=hits[i];h.finalScore=(row["relevance_score"] as? NSNumber)?.doubleValue ?? (row["score"] as? NSNumber)?.doubleValue ?? h.finalScore;out.append(h)}
        return out.isEmpty ? Array(hits.prefix(topN)):out
    }
}
