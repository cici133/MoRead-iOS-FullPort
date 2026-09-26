import Foundation

struct AIClient {
    struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let stream: Bool = false
    }
    struct ChatResponse: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
        let choices: [Choice]
    }

    let settings: AISettings
    let apiKey: String

    func chat(messages: [AIMessage], context: String) async throws -> String {
        let endpoint = URL(string: settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions")!
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let system = AIMessage(role: "system", content: "你是 MoRead 阅读伴读。仅根据用户提供的阅读上下文回答，不要剧透未提供的章节。\n阅读上下文：\n\(context)")
        let all = [system] + messages
        let payload = ChatRequest(model: settings.model, messages: all.map { .init(role: $0.role, content: $0.content) })
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }
}
