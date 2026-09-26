import Foundation

/// Optional post-turn reply suggestions. This service intentionally never mutates the
/// conversation and does not receive book text: the Android implementation only uses a bounded
/// recent transcript, which prevents this convenience call from widening the reading scope.
actor ReplySuggestionService {
    static let shared = ReplySuggestionService()

    func suggest(
        book: Book,
        chapter: Chapter,
        visibleText _: String,
        conversationId: Int64?,
        persona: PersonaRecord?
    ) async throws -> [String] {
        guard let conversationId else { return [] }
        let messages = try await AIConversationRepository.shared.messages(conversationId: conversationId)
            .filter { ($0.role == "user" || $0.role == "assistant") && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(8)
        guard let last = messages.last, last.role == "assistant" else { return [] }

        let transcript = messages.map { row in
            let speaker = row.role == "user" ? "用户" : (persona?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? persona!.name : "AI")
            return "\(speaker)：\(String(row.content.prefix(600)))"
        }.joined(separator: "\n")

        let resolved: ResolvedChatClient
        do {
            // AIProviderRepository.resolve(.suggestion) already performs the Android-compatible
            // SUGGESTION -> CHEAP -> CHAT fallback only when a higher-priority role is unassigned.
            resolved = try await AIClientFactory.forRole(.suggestion)
        } catch let error as AIClientError {
            if case .unsupported = error { return [] }
            throw error
        }

        let system = """
        你是阅读应用「墨知」伴读聊天的输入联想助手。用户正在阅读《\(book.title)》，当前章节是「\(chapter.title)」，对话对象是角色「\(persona?.name ?? "伴读")」。
        根据最近对话，替用户拟 3 条接下来可能想发送的回复。要求：口语化简体中文，每条不超过 16 个字；角度彼此不同（追问、回应感受、换话题皆可）；不要剧透用户还没读到的内容，不要重复已有的话；不要替用户编造个人经历。
        只输出 JSON 字符串数组，不要 Markdown，不要解释。
        """
        let raw = try await resolved.client.chat(
            messages: [
                .init(role: .system, content: system),
                .init(role: .user, content: String(transcript.prefix(6_000)))
            ],
            options: resolved.options
        )
        return Self.parse(raw)
    }

    static func parse(_ raw: String) -> [String] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json") { text.removeFirst(7) }
        else if text.hasPrefix("```") { text.removeFirst(3) }
        if text.hasSuffix("```") { text.removeLast(3) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        func decode(_ candidate: String) -> [String] {
            guard let data = candidate.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
            let values: [Any]
            if let array = root as? [Any] { values = array }
            else if let object = root as? [String: Any], let array = object["suggestions"] as? [Any] { values = array }
            else { return [] }
            var seen = Set<String>()
            return values.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .prefix(3)
                .map { String($0.prefix(40)) }
        }

        let direct = decode(text)
        if !direct.isEmpty || text == "[]" { return direct }
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else { return [] }
        return decode(String(text[start...end]))
    }
}
