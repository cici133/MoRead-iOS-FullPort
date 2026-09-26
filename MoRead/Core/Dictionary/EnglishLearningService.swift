import Foundation

actor EnglishLearningService {
    static let shared = EnglishLearningService()

    func enrich(word: String, context: String, localDefinitions: [DictionaryDefinition]) async -> AiDictionaryEntry {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.range(of: #"^[A-Za-z][A-Za-z'’-]{0,79}$"#, options: .regularExpression) != nil else {
            return .init(markdown: localDefinitions.first?.html ?? "")
        }
        do {
            let resolved = try await AIClientFactory.forRole(.translation)
            let request = AIChatMessage(role: .user, content: "请解释词语「\(clean)」。只输出 JSON：{\"label\":\"中文标注\",\"phonetic\":\"音标\",\"gloss\":\"词下短释义\",\"markdown\":\"详细释义\"}。语境：\(context.prefix(1200))")
            let raw = try await resolved.client.chat(messages: [
                .init(role: .system, content: "你是英语阅读词汇助手。音标优先 IPA；短释义不超过 18 个中文字符；不要猜测语境中不存在的词义。只输出要求的 JSON。"),
                request
            ], options: resolved.options)
            var entry = AiDictionaryEntry.parse(raw)
            if entry.markdown.isEmpty { entry.markdown = localDefinitions.first?.html ?? "" }
            return entry
        } catch {
            return .init(markdown: localDefinitions.first?.html ?? "")
        }
    }
}
