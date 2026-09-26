import Foundation

struct TxtTocRule: Identifiable, Hashable, Sendable {
    let id: Int64
    var enable: Bool
    let name: String
    let rule: String
    let example: String
    let serialNumber: Int
}

struct TxtSplitChapter: Identifiable, Hashable, Sendable {
    var id: Int { index }
    let index: Int
    let title: String
    let content: String
    let startOffset: Int
    let endOffset: Int
    var charCount: Int { (content as NSString).length }
}

struct TxtSplitResult: Hashable, Sendable {
    let rule: TxtTocRule?
    let chapters: [TxtSplitChapter]
    let score: Double
    var usedFallback = false
}

struct TxtImportSource: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let text: String
}

enum TxtChapterSplitter {
    static let minReasonableChapters = 4
    static let maxTitleLength = 80
    static let fallbackChapterSize = 10_000
    static let customRuleId = Int64.min

    static func chooseBest(_ text: String, rules: [TxtTocRule] = rules) -> TxtSplitResult {
        let candidates = rules.filter { $0.enable && !$0.rule.isEmpty }
            .compactMap { split(text, rule: $0) }
            .filter { $0.chapters.count >= minReasonableChapters }
        return candidates.max(by: { $0.score < $1.score }) ?? fallback(text)
    }

    static func split(_ text: String, customRegex: String) -> TxtSplitResult? {
        split(text, rule: .init(id: customRuleId, enable: true, name: "自定义规则", rule: customRegex, example: "", serialNumber: .max))
    }

    static func split(_ text: String, rule: TxtTocRule) -> TxtSplitResult? {
        guard !rule.rule.isEmpty, let regex = try? NSRegularExpression(pattern: rule.rule, options: [.anchorsMatchLines]) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var headings: [(start: Int, end: Int, title: String)] = []
        var seen = Set<Int>()
        for match in matches {
            let matchStart = match.range.location
            let beforeRange = NSRange(location: 0, length: max(0, matchStart))
            let previousNewline = ns.range(of: "\n", options: .backwards, range: beforeRange).location
            let lineStart = previousNewline == NSNotFound ? 0 : previousNewline + 1
            let afterStart = min(ns.length, NSMaxRange(match.range))
            let afterRange = NSRange(location: afterStart, length: max(0, ns.length - afterStart))
            let nextNewline = ns.range(of: "\n", options: [], range: afterRange).location
            let lineEnd = nextNewline == NSNotFound ? ns.length : nextNewline
            let title = ns.substring(with: NSRange(location: lineStart, length: max(0, lineEnd - lineStart))).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, (title as NSString).length <= maxTitleLength, seen.insert(lineStart).inserted else { continue }
            headings.append((lineStart, lineEnd, title))
        }
        headings.sort { $0.start < $1.start }
        guard headings.count >= 2 else { return nil }
        var chapters: [TxtSplitChapter] = []
        if headings[0].start > 0 {
            let preface = ns.substring(with: NSRange(location: 0, length: headings[0].start)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !preface.isEmpty { chapters.append(.init(index: chapters.count, title: "序章", content: preface, startOffset: 0, endOffset: headings[0].start)) }
        }
        for (index, heading) in headings.enumerated() {
            let chapterEnd = index + 1 < headings.count ? headings[index + 1].start : ns.length
            let bodyStart = min(heading.end, chapterEnd)
            let body = ns.substring(with: NSRange(location: bodyStart, length: max(0, chapterEnd - bodyStart))).trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(.init(index: chapters.count, title: heading.title, content: body, startOffset: heading.start, endOffset: chapterEnd))
        }
        return .init(rule: rule, chapters: chapters, score: score(chapters))
    }

    private static func score(_ chapters: [TxtSplitChapter]) -> Double {
        guard !chapters.isEmpty else { return -.infinity }
        let lengths = chapters.map { max(1, $0.charCount) }
        let average = Double(lengths.reduce(0, +)) / Double(lengths.count)
        let shortRatio = Double(lengths.filter { $0 < 80 }.count) / Double(lengths.count)
        let hugeRatio = Double(lengths.filter { $0 > 120_000 }.count) / Double(lengths.count)
        let idealDistance = abs(average - 8_000) / 8_000
        return Double(chapters.count) * 100 - shortRatio * 2_000 - hugeRatio * 5_000 - min(5, idealDistance) * 30
    }

    private static func fallback(_ text: String) -> TxtSplitResult {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = normalized as NSString
        guard ns.length > 0 else { return .init(rule: nil, chapters: [], score: 0, usedFallback: true) }
        var chapters: [TxtSplitChapter] = [], start = 0
        while start < ns.length {
            let desired = min(ns.length, start + fallbackChapterSize)
            var end = desired
            if desired < ns.length {
                let limit = min(ns.length, desired + 2_000)
                let hit = ns.range(of: "\n\n", options: [], range: NSRange(location: desired, length: max(0, limit - desired)))
                if hit.location != NSNotFound { end = hit.location }
            }
            if end <= start { end = min(ns.length, start + fallbackChapterSize) }
            let content = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(.init(index: chapters.count, title: chapters.isEmpty ? "正文" : "第 \(chapters.count + 1) 节", content: content, startOffset: start, endOffset: end))
            start = end
        }
        return .init(rule: nil, chapters: chapters, score: 0, usedFallback: true)
    }

    /// Port of MoRead/Legado's txtTocRule asset. Disabled rules remain selectable in import preview.
    static let rules: [TxtTocRule] = [
        .init(id:-1,enable:true,name:"目录(去空白)",rule:#"(?<=[　\s])(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和]))).{0,30}$"#,example:"第一章 假装第一章前面有空白但我不要",serialNumber:0),
        .init(id:-2,enable:true,name:"目录",rule:#"^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?![分赛游])|篇(?!张))).{0,30}$"#,example:"第一章 标准的粤语就是这样",serialNumber:1),
        .init(id:-3,enable:false,name:"目录(匹配简介)",rule:#"(?<=[　\s])(?:(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?![分赛游])|回(?![合来事去])|场(?![和合比电是])|篇(?!张))).{0,30}$"#,example:"简介 老夫诸葛村夫",serialNumber:2),
        .init(id:-4,enable:false,name:"目录(古典、轻小说备用)",rule:#"^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|集(?![合和])|部(?![分赛游])|回(?![合来事去])|场(?![和合比电是])|话|篇(?!张))).{0,30}$"#,example:"第一章 比上面只多了回和话",serialNumber:3),
        .init(id:-5,enable:false,name:"数字(纯数字标题)",rule:#"(?<=[　\s])\d+\.?[ 　\t]{0,4}$"#,example:"12",serialNumber:4),
        .init(id:-6,enable:false,name:"大写数字(纯数字标题)",rule:#"(?<=[　\s])[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,12}[ 　\t]{0,4}$"#,example:"一百七十",serialNumber:5),
        .init(id:-7,enable:false,name:"数字混合(纯数字标题)",rule:#"(?<=[　\s])[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟\d]{1,12}[ 　\t]{0,4}$"#,example:"12\n一百七十",serialNumber:6),
        .init(id:-8,enable:true,name:"数字 分隔符 标题名称",rule:#"^[ 　\t]{0,4}\d{1,5}[:：,.， 、_—\-].{1,30}$"#,example:"1、这个就是标题",serialNumber:7),
        .init(id:-9,enable:true,name:"大写数字 分隔符 标题名称",rule:#"^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章?)[ 、_—\-].{1,30}$"#,example:"一、只有前面的数字有差别",serialNumber:8),
        .init(id:-10,enable:false,name:"数字混合 分隔符 标题名称",rule:#"^[ 　\t]{0,4}(?:序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章?[ 、_—\-]|\d{1,5}章?[:：,.， 、_—\-]).{0,30}$"#,example:"1、人参公鸡",serialNumber:9),
        .init(id:-11,enable:true,name:"正文 标题/序号",rule:#"^[ 　\t]{0,4}正文[ 　]{1,4}.{0,20}$"#,example:"正文 我奶常山赵子龙",serialNumber:10),
        .init(id:-12,enable:true,name:"Chapter/Section/Part/Episode 序号 标题",rule:#"^[ 　\t]{0,4}(?:[Cc]hapter|[Ss]ection|[Pp]art|ＰＡＲＴ|[Nn][oO][.、]|[Ee]pisode|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)\s{0,4}\d{1,4}.{0,30}$"#,example:"Chapter 1 MyGrandmaIsNB",serialNumber:11),
        .init(id:-13,enable:false,name:"Chapter(去简介)",rule:#"^[ 　\t]{0,4}(?:[Cc]hapter|[Ss]ection|[Pp]art|ＰＡＲＴ|[Nn][Oo]\.|[Ee]pisode)\s{0,4}\d{1,4}.{0,30}$"#,example:"Chapter 1 MyGrandmaIsNB",serialNumber:12),
        .init(id:-14,enable:true,name:"特殊符号 序号 标题",rule:#"(?<=[\s　])[【〔〖「『〈［\[](?:第|[Cc]hapter)[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,10}[章节].{0,20}$"#,example:"【第一章 后面的符号可以没有",serialNumber:13),
        .init(id:-15,enable:false,name:"特殊符号 标题(成对)",rule:#"(?<=[\s　]{0,4})(?:[\[〈「『〖〔《（【\(].{1,30}[\)】）》〕〗』」〉\]]?|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)[ 　]{0,4}$"#,example:"『加个直角引号更专业』",serialNumber:14),
        .init(id:-16,enable:true,name:"特殊符号 标题(单个)",rule:#"(?<=[\s　]{0,4})(?:[☆★✦✧].{1,30}|(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外)[ 　]{0,4}$"#,example:"☆、晋江作者最喜欢的格式",serialNumber:15),
        .init(id:-17,enable:true,name:"章/卷 序号 标题",rule:#"^[ \t　]{0,4}(?:(?:内容|文章)?简介|文案|前言|序章|楔子|正文(?!完|结)|终章|后记|尾声|番外|[卷章][\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8})[ 　]{0,4}.{0,30}$"#,example:"卷五 开源盛世",serialNumber:16),
        .init(id:-18,enable:false,name:"顶格标题",rule:#"^\S.{1,20}$"#,example:"20字以内顶格写的都是标题",serialNumber:17),
        .init(id:-19,enable:false,name:"双标题(前向)",rule:#"(?m)(?<=[ \t　]{0,4})第[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章.{0,30}$(?=[\s　]{0,8}第[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章)"#,example:"第一章 真正的标题",serialNumber:18),
        .init(id:-20,enable:false,name:"双标题(后向)",rule:#"(?m)(?<=[ \t　]{0,4}第[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章.{0,30}$[\s　]{0,8})第[\d零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}章.{0,30}$"#,example:"第一章真正的标题",serialNumber:19),
        .init(id:-21,enable:true,name:"书名 括号 序号",rule:#"^[一-龥]{1,20}[ 　\t]{0,4}[(（][\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[)）][ 　\t]{0,4}$"#,example:"标题后面数字有括号(12)",serialNumber:20),
        .init(id:-22,enable:true,name:"书名 序号",rule:#"^[一-龥]{1,20}[ 　\t]{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]{1,8}[ 　\t]{0,4}$"#,example:"标题后面数字没有括号124",serialNumber:21),
        .init(id:-23,enable:false,name:"特定字符 标题 特定符号",rule:#"(?<=\={3,6}).{1,40}?(?=\=)"#,example:"===起这种标题干什么===",serialNumber:22),
        .init(id:-24,enable:true,name:"字数分割 分节阅读",rule:#"(?<=[ 　\t]{0,4})(?:.{0,15}分[页节章段]阅读[-_ ]|第\s{0,4}[\d零一二两三四五六七八九十百千万]{1,6}\s{0,4}[页节]).{0,30}$"#,example:"分节|分页|分段阅读",serialNumber:23),
        .init(id:-25,enable:false,name:"通用规则",rule:#"(?im)^.{0,6}(?:[引楔]子|正文(?!完|结)|[引序前]言|[序终]章|扉页|[上中下][部篇卷]|卷首语|后记|尾声|番外|={2,4}|第\s{0,4}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+?\s{0,4}(?:章|节(?!课)|卷|页[、 　]|集(?![合和])|部(?![分是门落])|篇(?!张))).{0,40}$|^.{0,6}[\d〇零一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟a-z]{1,8}[、. 　].{0,20}$"#,example:"激进规则,适配更多非常用格式",serialNumber:24),
        .init(id:-100,enable:false,name:"默认分章规则",rule:"",example:"兜底规则，请勿改动此内容",serialNumber:99)
    ]
}
