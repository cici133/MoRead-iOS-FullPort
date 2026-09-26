import Foundation

struct ReaderTextReplacementRule: Codable, Identifiable, Hashable, Sendable {
    var id: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var name = "新规则"
    var pattern = ""
    var replacement = ""
    var enabled = true
    var ignoreCase = false
    var forListenOnly = false
    var isRegex = true

    func regex() throws -> NSRegularExpression {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReaderEnhancementError.message("规则名称不能为空") }
        guard !pattern.isEmpty, pattern.count <= 1000 else { throw ReaderEnhancementError.message("匹配表达式不能为空且不能超过 1000 字") }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if ignoreCase { options.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: isRegex ? pattern : NSRegularExpression.escapedPattern(for: pattern), options: options)
    }
}

struct ReaderSyntaxRule: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var name = "高亮规则"
    var pattern = ""
    var enabled = true
    var ignoreCase = false
    var colorHex = "#A6513D"
    var backgroundHex = "#FFF1D6"
    var bold = false
    var italic = false
    var underline = false
}

struct ReaderTitleStyle: Codable, Hashable, Sendable {
    var enabled = true
    var fontFamily = "-apple-system"
    var fontSizeEm = 1.45
    var colorHex = ""
    var backgroundHex = ""
    var alignment = "center"
    var marginTopEm = 0.8
    var marginBottomEm = 1.2
    var paddingEm = 0.35
    var borderColorHex = ""
    var borderWidthEm = 0.0
    var borderRadiusEm = 0.0
    var backgroundImagePath: String?
}

struct NamedReaderTitleStyle: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name = "章首样式"
    var style = ReaderTitleStyle()
}

struct ReaderEnhancementSettings: Codable, Equatable, Hashable, Sendable {
    var replacementRules: [ReaderTextReplacementRule] = []
    var syntaxRules: [ReaderSyntaxRule] = []
    var titleStyle = ReaderTitleStyle()
    var titleStylePresets: [NamedReaderTitleStyle]?
    var activeTitleStyleId: String?

    var resolvedTitlePresets: [NamedReaderTitleStyle] { titleStylePresets ?? [] }
}

@MainActor final class ReaderEnhancementSettingsStore: ObservableObject {
    static let shared = ReaderEnhancementSettingsStore()
    @Published var settings: ReaderEnhancementSettings { didSet { save() } }
    private let url: URL
    private init() {
        let root = (try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory
        url = root.appendingPathComponent("reader-enhancements.json")
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(ReaderEnhancementSettings.self, from: data) { settings = value }
        else { settings = .init() }
    }
    private func save() { if let data = try? JSONEncoder().encode(settings) { try? data.write(to: url, options: .atomic) } }
}

enum ReaderTextReplacementEngine {
    static func displayText(_ source: String, rules: [ReaderTextReplacementRule]) -> String {
        rules.filter { $0.enabled && !$0.forListenOnly }.reduce(source) { current, rule in
            guard let regex = try? rule.regex() else { return current }
            let range = NSRange(location: 0, length: (current as NSString).length)
            return regex.stringByReplacingMatches(in: current, range: range, withTemplate: rule.isRegex ? rule.replacement : escapedTemplate(rule.replacement))
        }
    }

    static func listeningText(_ source: String, start: Int, end: Int, rules: [ReaderTextReplacementRule]) -> (source: String, display: String, mapping: ReaderTextMapping) {
        let ns = source as NSString
        let a = min(max(0, start), ns.length), b = min(max(a, end), ns.length)
        let raw = ns.substring(with: NSRange(location: a, length: b - a))
        let purified = rules.filter { $0.enabled && $0.forListenOnly }.reduce(raw) { current, rule in
            guard let regex = try? rule.regex() else { return current }
            return regex.stringByReplacingMatches(in: current, range: NSRange(location: 0, length: (current as NSString).length), withTemplate: rule.isRegex ? rule.replacement : escapedTemplate(rule.replacement))
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw, purified, ReaderTextMapping(source: raw, display: purified))
    }

    static func audiobookRevision(_ body: String, rules: [ReaderTextReplacementRule]) -> Int {
        let fingerprint = rules.filter { $0.enabled && $0.forListenOnly }.map { "\($0.id)\u{1}\($0.pattern)\u{1}\($0.replacement)\u{1}\($0.ignoreCase)\u{1}\($0.isRegex)" }.joined(separator: "\u{0}")
        return AudiobookRevision.hash(body + "\u{2}" + fingerprint)
    }

    private static func escapedTemplate(_ value: String) -> String { value.replacingOccurrences(of: "$", with: "\\$") }
}

enum ReaderEnhancementError: LocalizedError { case message(String); var errorDescription: String? { switch self { case .message(let s): s } } }
