import Foundation

struct AIChapterRuleProposal: Sendable {
    var name: String
    var regex: String
    var reason: String
    var chapterCount: Int
    var sampleTitles: [String]
}

enum AIChapterRuleService {
    static func propose(text: String, current: TxtSplitResult, onAttempt: @escaping @Sendable (Int) async -> Void = { _ in }) async throws -> AIChapterRuleProposal {
        let sample = structuralSample(text)
        let resolved = try await AIClientFactory.forRole(.cheap)
        var messages: [AIChatMessage] = [
            .init(role: .system, content: systemPrompt),
            .init(role: .user, content: "请为这份 TXT 探寻章节标题正则。\n当前本地规则：\(current.rule?.name ?? "按字数分节")\n当前结果：\(current.chapters.count) 节\n下方仅是去除正文语义后的行结构样本，0/汉/A 是脱敏占位符：\n\(sample)")
        ]
        var last = "模型没有返回可用规则"
        for attempt in 1...3 {
            await onAttempt(attempt)
            var options = resolved.options; options.temperature = 0.1; options.maxTokens = options.maxTokens ?? 900
            let response = try await resolved.client.chat(messages: messages, options: options)
            if let draft = parse(response) {
                switch validate(text: text, regex: draft.regex) {
                case .success(let result):
                    return .init(name: draft.name, regex: draft.regex, reason: draft.reason, chapterCount: result.chapters.count, sampleTitles: result.chapters.filter { $0.title != "序章" }.prefix(6).map(\.title))
                case .failure(let reason): last = reason
                }
            } else { last = "返回内容不是约定 JSON，或缺少 name、regex、reason" }
            messages.append(.init(role: .assistant, content: response))
            messages.append(.init(role: .user, content: "本地全文验证失败：\(last)。请修正规则后仍只输出约定 JSON。"))
        }
        throw AIClientError.malformed("AI 连续 3 次未找到可靠规则：\(last)")
    }

    private struct Draft { var name: String; var regex: String; var reason: String }
    private enum Validation { case success(TxtSplitResult), failure(String) }

    private static func parse(_ response: String) -> Draft? {
        guard let a = response.firstIndex(of: "{"), let b = response.lastIndex(of: "}"), a < b,
              let data = String(response[a...b]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let regex = (root["regex"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !regex.isEmpty,
              let reason = (root["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return nil }
        return .init(name: String(name.prefix(40)), regex: regex, reason: String(reason.prefix(240)))
    }

    private static func validate(text: String, regex: String) -> Validation {
        if regex.count > 400 { return .failure("正则超过 400 字符") }
        if !regex.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("^") || !regex.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("$") { return .failure("正则必须以 ^ 开头并以 $ 结尾") }
        if let nested = try? NSRegularExpression(pattern: #"\([^)]*[+*][^)]*\)[+*{]"#), nested.firstMatch(in: regex, range: NSRange(location: 0, length: (regex as NSString).length)) != nil { return .failure("正则包含可能造成灾难性回溯的嵌套量词") }
        guard let re = try? NSRegularExpression(pattern: regex, options: [.anchorsMatchLines]) else { return .failure("正则无法编译") }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.count < 2 { return .failure("全文只匹配到 \(matches.count) 个标题") }
        if matches.count > 20_000 { return .failure("匹配结果超过 20000 个，疑似误中正文") }
        for match in matches.prefix(20_001) {
            let value = ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !(1...80).contains((value as NSString).length) { return .failure("规则命中了空行或超过 80 字的正文行") }
        }
        guard let result = TxtChapterSplitter.split(text, customRegex: regex) else { return .failure("规则未形成至少两个有效章节") }
        let content = result.chapters.filter { $0.title != "序章" }
        if content.count >= 5 {
            let shortRatio = Double(content.filter { $0.charCount < 20 }.count) / Double(max(1, content.count))
            if shortRatio > 0.35 { return .failure("超过三分之一章节正文不足 20 字，疑似匹配过宽") }
        }
        let distinctRatio = Double(Set(content.map(\.title)).count) / Double(max(1, content.count))
        if distinctRatio < 0.6 { return .failure("章节标题重复过多，规则不可靠") }
        return .success(result)
    }

    private static func structuralSample(_ text: String) -> String {
        guard !text.isEmpty else { return "（空文本）" }
        let ns = text as NSString
        let fractions: [Double] = [0, 0.25, 0.5, 0.75, 1]
        return fractions.enumerated().map { index, fraction in
            let center = min(ns.length, max(0, Int(Double(ns.length) * fraction)))
            let start = max(0, center - 2_000), end = min(ns.length, start + 4_000)
            let chunk = ns.substring(with: NSRange(location: start, length: end - start))
            let lines = chunk.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && $0.count <= 80 }
                .map { ($0, likelihood($0)) }.sorted { $0.1 > $1.1 }.prefix(18).map { redact($0.0) }
            return "【样本 \(index + 1)/5 · 位置 \(Int(fraction * 100))%】\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func likelihood(_ line: String) -> Int {
        var score = line.count <= 40 ? 3 : 0
        if line.range(of: #"第.+[章节卷回部篇集]|chapter|part|volume|prologue|epilogue"#, options: [.regularExpression, .caseInsensitive]) != nil { score += 6 }
        if line.contains(where: \.isNumber) { score += 2 }
        if let f = line.first, "=-—●◆【〔（(".contains(f) { score += 2 }
        if let l = line.last, "=】〕）)".contains(l) { score += 2 }
        if let l = line.last, "。！？；.!?;".contains(l) { score -= 5 }
        return score
    }

    private static func redact(_ line: String) -> String {
        let markers = Set(["chapter","part","volume","book","prologue","epilogue"])
        let structural = Set("第章节卷回部篇集序幕终楔引后前番话一二三四五六七八九十百千万零两")
        var output = "", i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c.isASCII && c.isLetter {
                var j = line.index(after: i); while j < line.endIndex && line[j].isASCII && line[j].isLetter { j = line.index(after: j) }
                let word = String(line[i..<j]); output += markers.contains(word.lowercased()) ? word : "A"; i = j; continue
            }
            if c.isNumber { output.append("0") }
            else if structural.contains(c) { output.append(c) }
            else if c.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains(Int($0.value)) }) { output.append("汉") }
            else if c.isLetter { output.append("A") }
            else { output.append(c) }
            i = line.index(after: i)
        }
        return output
    }

    private static let systemPrompt = """
    你是 TXT 章节结构识别代理。根据跨越开头、中部、末尾的脱敏行结构样本，推断一个 Kotlin/Java 正则。
    正则会以 MULTILINE 模式运行，必须用 ^ 和 $ 匹配完整标题行，不得匹配正文；控制在 400 字符内。
    JSON 中的反斜杠必须正确转义。若标题存在多种稳定格式，可用非捕获分组合并。
    只输出单个 JSON 对象，不要 Markdown、注释或额外文字：
    {"name":"简短规则名","regex":"^...$","reason":"一句话说明判断依据"}
    """
}
