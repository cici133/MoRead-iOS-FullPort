import Foundation

enum AIChapterRuleAgent {
    static func propose(text: String, onAttempt: @Sendable (Int) async -> Void = { _ in }) async throws -> AIChapterRuleProposal {
        let sample = AIChapterRuleSampler.sample(text)
        let resolved = try await AIClientFactory.forRole(.cheap)
        let system = """
        你是 TXT 章节结构识别代理。根据跨越开头、中部、末尾的脱敏行结构样本，推断一个 ICU/NSRegularExpression 可用的正则。
        正则会以 MULTILINE 模式运行，必须用 ^ 和 $ 匹配完整标题行，不得匹配正文；控制在 400 字符内。
        JSON 中的反斜杠必须正确转义。若标题存在多种稳定格式，可用非捕获分组合并。
        只输出单个 JSON 对象，不要 Markdown、注释或额外文字：
        {"name":"简短规则名","regex":"^...$","reason":"一句话说明判断依据"}
        """
        var messages: [AIChatMessage] = [
            .init(role: .system, content: system),
            .init(role: .user, content: "请为这份 TXT 探寻章节标题正则。下方只包含脱敏后的行结构，0/汉/A 是占位符：\n\n\(sample)")
        ]
        var lastFailure = "模型没有返回可用规则"
        for attempt in 1...3 {
            await onAttempt(attempt)
            var options = resolved.options
            options.temperature = 0.1
            if options.maxTokens == nil { options.maxTokens = 900 }
            let response = try await resolved.client.chat(messages: messages, options: options)
            if let draft = parse(response) {
                switch validate(text: text, regex: draft.regex) {
                case .success(let result):
                    return .init(
                        name: draft.name, regex: draft.regex, reason: draft.reason,
                        chapterCount: result.chapters.count,
                        sampleTitles: result.chapters.filter { $0.title != "序章" }.prefix(6).map(\.title)
                    )
                case .failure(let error): lastFailure = error.localizedDescription
                }
            } else { lastFailure = "返回内容不是约定 JSON，或缺少 name、regex、reason" }
            messages.append(.init(role: .assistant, content: response))
            messages.append(.init(role: .user, content: "本地全文验证失败：\(lastFailure)。请修正规则后仍只输出约定 JSON。"))
        }
        throw AIChapterRuleError.message("AI 连续 3 次未找到可靠规则：\(lastFailure)")
    }

    private struct Draft { var name: String; var regex: String; var reason: String }
    private static func parse(_ response: String) -> Draft? {
        guard let a = response.firstIndex(of: "{"), let b = response.lastIndex(of: "}"), a < b,
              let data = String(response[a...b]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = String((root["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let regex = (root["regex"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = String((root["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        return name.isEmpty || regex.isEmpty || reason.isEmpty ? nil : .init(name: name, regex: regex, reason: reason)
    }

    private static func validate(text: String, regex: String) -> Result<TxtSplitResult, AIChapterRuleError> {
        guard regex.count <= 400 else { return .failure(.message("正则超过 400 字符")) }
        guard regex.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("^"),
              regex.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("$") else {
            return .failure(.message("正则必须以 ^ 开头并以 $ 结尾"))
        }
        if regex.range(of: #"\([^)]*[+*][^)]*\)[+*{]"#, options: .regularExpression) != nil {
            return .failure(.message("正则包含可能造成灾难性回溯的嵌套量词"))
        }
        let compiled: NSRegularExpression
        do { compiled = try NSRegularExpression(pattern: regex, options: [.anchorsMatchLines]) }
        catch { return .failure(.message("正则无法编译：\(error.localizedDescription)")) }
        let ns = text as NSString
        let matches = compiled.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return .failure(.message("全文只匹配到 \(matches.count) 个标题")) }
        guard matches.count <= 20_000 else { return .failure(.message("匹配结果超过 20000 个，疑似误中正文")) }
        for match in matches.prefix(20_001) {
            let value = ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            if (value as NSString).length < 1 || (value as NSString).length > 80 { return .failure(.message("规则命中了空行或超过 80 字的正文行")) }
        }
        guard let result = TxtChapterSplitter.split(text, customRegex: regex), result.chapters.count >= 2 else {
            return .failure(.message("规则未形成至少两个有效章节"))
        }
        let chapters = result.chapters.filter { $0.title != "序章" }
        if chapters.count >= 5 {
            let shortRatio = Double(chapters.filter { $0.charCount < 20 }.count) / Double(max(1, chapters.count))
            if shortRatio > 0.35 { return .failure(.message("超过三分之一章节正文不足 20 字，疑似匹配过宽")) }
        }
        let distinctRatio = Double(Set(chapters.map(\.title)).count) / Double(max(1, chapters.count))
        if distinctRatio < 0.6 { return .failure(.message("章节标题重复过多，规则不可靠")) }
        return .success(result)
    }
}

enum AIChapterRuleError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): value } }
}

private enum AIChapterRuleSampler {
    static func sample(_ text: String) -> String {
        guard !text.isEmpty else { return "（空文本）" }
        let ns = text as NSString, fractions: [Double] = [0, 0.25, 0.5, 0.75, 1]
        return fractions.enumerated().map { index, fraction in
            let center = min(ns.length, max(0, Int(Double(ns.length) * fraction)))
            let start = min(max(0, center - 2_000), ns.length)
            let end = min(ns.length, start + 4_000)
            let block = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            let lines = block.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && ($0 as NSString).length <= 80 }
                .map { ($0, headingScore($0)) }
                .sorted { $0.1 > $1.1 }
                .prefix(18)
                .map { redact($0.0) }
            return "【样本 \(index + 1)/5 · 位置 \(Int(fraction * 100))%】\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func headingScore(_ line: String) -> Int {
        var score = (line as NSString).length <= 40 ? 3 : 0
        if line.range(of: #"第.+[章节卷回部篇集]|chapter|part|volume|prologue|epilogue"#, options: [.regularExpression, .caseInsensitive]) != nil { score += 6 }
        if line.contains(where: { $0.isNumber }) { score += 2 }
        if let first = line.first, "=-—●◆【〔（(".contains(first) { score += 2 }
        if let last = line.last, "=】〕）)".contains(last) { score += 2 }
        if let last = line.last, "。！？；.!?;".contains(last) { score -= 5 }
        return score
    }

    private static func isASCII(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        return scalars.count == 1 && scalars.first?.isASCII == true
    }

    private static let structuralCJK = Set("第章节卷回部篇集序幕终楔引后前番话一二三四五六七八九十百千万零两")
    private static let markerWords = Set(["chapter","part","volume","book","prologue","epilogue"])
    private static func redact(_ line: String) -> String {
        var result = "", index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch.isLetter && isASCII(ch) {
                var end = line.index(after: index)
                while end < line.endIndex, line[end].isLetter, isASCII(line[end]) { end = line.index(after: end) }
                let word = String(line[index..<end])
                result += markerWords.contains(word.lowercased()) ? word : "A"
                index = end; continue
            }
            if ch.isNumber { result.append("0") }
            else if structuralCJK.contains(ch) { result.append(ch) }
            else if (ch.unicodeScalars.first.map { (0x4E00...0x9FFF).contains(Int($0.value)) } ?? false) { result.append("汉") }
            else if ch.isLetter { result.append("A") }
            else { result.append(ch) }
            index = line.index(after: index)
        }
        return result
    }
}
