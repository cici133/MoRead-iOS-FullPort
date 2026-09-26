import Foundation
import UIKit

struct ReviewShareTemplate: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var backgroundARGB: UInt32 = 0xFFF7F5EF
    var textARGB: UInt32 = 0xFF495963
    var accentARGB: UInt32 = 0xFF7E9CB5
    var fontChoice: String = ""
    var css: String = ""
}

struct ReviewTemplateStyle: Sendable {
    var fontSizeEm: CGFloat = 1
    var lineHeight: CGFloat = 1.55
    var letterSpacingEm: CGFloat = 0
    var paddingEm: CGFloat = 2.0
    var topEm: CGFloat = 0
    var bottomEm: CGFloat = 0
    var cornerRadiusEm: CGFloat = 0
    var italic = false
    var underline = false
    var errors: [String] = []

    static func parse(_ css: String) -> Self {
        var result = Self()
        guard css.utf8.count <= 4_000 else { result.errors = ["CSS 不能超过 4000 字节"]; return result }
        let cleaned = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        for declaration in cleaned.split(separator: ";") {
            let text = String(declaration)
            let key = text.split(separator: ":", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let value = text.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            func em(_ raw: String) -> CGFloat? { Double(raw.replacingOccurrences(of: "em", with: "")).map { CGFloat($0) } }
            switch key {
            case "font-size":
                if let v = em(value), (0.5...3).contains(v) { result.fontSizeEm = v } else { result.errors.append("font-size：请使用 0.5em～3em") }
            case "line-height":
                if let v = em(value), (1...2.5).contains(v) { result.lineHeight = v } else { result.errors.append("line-height：请使用 1～2.5") }
            case "letter-spacing":
                if let v = em(value), (-0.05...0.3).contains(v) { result.letterSpacingEm = v } else { result.errors.append("letter-spacing：请使用 -0.05em～0.3em") }
            case "padding":
                if let v = em(value), (0...6).contains(v) { result.paddingEm = v } else { result.errors.append("padding：请使用 0～6em") }
            case "margin-top":
                if let v = em(value), (0...6).contains(v) { result.topEm = v } else { result.errors.append("margin-top：请使用 0～6em") }
            case "margin-bottom":
                if let v = em(value), (0...6).contains(v) { result.bottomEm = v } else { result.errors.append("margin-bottom：请使用 0～6em") }
            case "border-radius":
                if let v = em(value), (0...6).contains(v) { result.cornerRadiusEm = v } else { result.errors.append("border-radius：请使用 0～6em") }
            case "font-style": result.italic = value.lowercased() == "italic"
            case "text-decoration": result.underline = value.lowercased().contains("underline")
            case "", "color", "background", "background-color", "font-family": break
            default: break // retain forward compatibility; unsupported declarations are ignored.
            }
        }
        return result
    }
}

@MainActor
final class ReviewShareTemplateStore: ObservableObject {
    static let shared = ReviewShareTemplateStore()
    @Published var templates: [ReviewShareTemplate] = [] { didSet { if !loading { save() } } }
    private let key = "moread.review.share.templates.v1"
    private var loading = true
    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let decoded = try? JSONDecoder().decode([ReviewShareTemplate].self, from: data) {
            templates = decoded.filter { !$0.id.isEmpty && !$0.name.isEmpty }
        }
        if templates.isEmpty {
            templates = [
                .init(id: "paper", name: "纸白"),
                .init(id: "mist", name: "雾蓝", backgroundARGB: 0xFFD7E6F2, textARGB: 0xFF354C5E, accentARGB: 0xFF6A94B5),
                .init(id: "night", name: "暗夜", backgroundARGB: 0xFF202930, textARGB: 0xFFD3DEE8, accentARGB: 0xFF9BBEDC)
            ]
        }
        loading = false
    }
    func upsert(_ template: ReviewShareTemplate) {
        if let index = templates.firstIndex(where: { $0.id == template.id }) { templates[index] = template }
        else { templates.append(template) }
    }
    func delete(_ id: String) { templates.removeAll { $0.id == id } }
    private func save() { if let data = try? JSONEncoder().encode(templates) { UserDefaults.standard.set(data, forKey: key) } }
}

enum ReviewCardExporter {
    static func image(entry: ReviewEntry, template: ReviewShareTemplate, includeThought: Bool = true, includeBook: Bool = true, includeDate: Bool = true, watermark: Bool = true, width: CGFloat = 1080) throws -> UIImage {
        let style = ReviewTemplateStyle.parse(template.css)
        guard style.errors.isEmpty else { throw ExportError(style.errors.joined(separator: "\n")) }
        let background = UIColor(argb: template.backgroundARGB)
        let textColor = UIColor(argb: template.textARGB)
        let accent = UIColor(argb: template.accentARGB)
        let em: CGFloat = 47
        let gutter = min(width * 0.4, max(24, style.paddingEm * em))
        let textWidth = width - gutter * 2
        let quote = entry.quote.isEmpty ? (entry.title.isEmpty ? "读书笔记" : entry.title) : entry.quote
        let quoteFont = font(named: template.fontChoice, size: em * style.fontSizeEm, italic: style.italic)
        let bodyFont = font(named: template.fontChoice, size: 32, italic: false)
        let metadataFont = UIFont.systemFont(ofSize: 26)
        let quoteAttrs = attributes(font: quoteFont, color: textColor, lineHeight: style.lineHeight, kern: style.letterSpacingEm * quoteFont.pointSize, underline: style.underline)
        let bodyAttrs = attributes(font: bodyFont, color: textColor, lineHeight: 1.5, kern: 0, underline: false)
        let metaAttrs: [NSAttributedString.Key: Any] = [.font: metadataFont, .foregroundColor: textColor]
        let quoteHeight = measure(quote, width: textWidth, attrs: quoteAttrs)
        let thought = includeThought ? plainText(entry.body) : ""
        let thoughtHeight = thought.isEmpty ? 0 : measure(thought, width: textWidth, attrs: bodyAttrs) + 92
        var meta: [String] = []
        if includeBook { meta.append("\(entry.book.title) · \(entry.locationLabel)") }
        if entry.personaId != nil { meta.append(entry.author) }
        if includeDate { meta.append(Date(timeIntervalSince1970: Double(entry.timestamp) / 1000).formatted(date: .numeric, time: .omitted)) }
        let metadata = meta.joined(separator: " · ")
        let metaHeight = measure(metadata, width: textWidth, attrs: metaAttrs)
        let height = max(920, 220 + style.topEm * em + quoteHeight + style.bottomEm * em + thoughtHeight + 120 + metaHeight + (watermark ? 150 : 90))
        guard height <= 8192 else { throw ExportError("这条内容较长，请使用 Markdown 导出以保留全文") }

        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(background.cgColor)
            let radius = min(width / 2, style.cornerRadiusEm * em)
            let path = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerRadius: radius)
            path.fill()
            accent.setFill()
            let ornament = "“" as NSString
            ornament.draw(at: CGPoint(x: gutter - 8, y: 48), withAttributes: [.font: UIFont(name: "TimesNewRomanPSMT", size: 150) ?? UIFont.systemFont(ofSize: 150), .foregroundColor: accent])
            var y: CGFloat = 216 + style.topEm * em
            draw(quote, rect: CGRect(x: gutter, y: y, width: textWidth, height: quoteHeight), attrs: quoteAttrs)
            y += quoteHeight + style.bottomEm * em
            if !thought.isEmpty {
                y += 56
                cg.setStrokeColor(accent.cgColor); cg.setLineWidth(3); cg.move(to: CGPoint(x: gutter, y: y)); cg.addLine(to: CGPoint(x: gutter + 80, y: y)); cg.strokePath(); y += 34
                draw(thought, rect: CGRect(x: gutter, y: y, width: textWidth, height: thoughtHeight - 92), attrs: bodyAttrs)
            }
            let metaY = height - metaHeight - (watermark ? 140 : 70)
            draw(metadata, rect: CGRect(x: gutter, y: metaY, width: textWidth, height: metaHeight + 10), attrs: metaAttrs)
            if watermark { ("墨知 MoRead" as NSString).draw(at: CGPoint(x: gutter, y: height - 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: accent]) }
        }
    }

    static func writePNG(entry: ReviewEntry, template: ReviewShareTemplate) throws -> URL {
        let image = try image(entry: entry, template: template)
        guard let data = image.pngData() else { throw ExportError("无法编码分享图片") }
        let root = try MoReadDatabase.applicationDirectory().appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("MoRead-回顾-\(UUID().uuidString).png")
        try data.write(to: file, options: .atomic)
        return file
    }

    private static func font(named name: String, size: CGFloat, italic: Bool) -> UIFont {
        if !name.isEmpty, let custom = UIFont(name: name, size: size) { return custom }
        return italic ? UIFont.italicSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size, weight: .regular)
    }
    private static func attributes(font: UIFont, color: UIColor, lineHeight: CGFloat, kern: CGFloat, underline: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineHeightMultiple = lineHeight
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph, .kern: kern]
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }
    private static func measure(_ text: String, width: CGFloat, attrs: [NSAttributedString.Key: Any]) -> CGFloat {
        ceil((text as NSString).boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).height)
    }
    private static func draw(_ text: String, rect: CGRect, attrs: [NSAttributedString.Key: Any]) { (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil) }
    private static func plainText(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"!\[([^]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "~~", with: "").replacingOccurrences(of: "`", with: "")
    }
    struct ExportError: LocalizedError { let text: String; init(_ text: String) { self.text = text }; var errorDescription: String? { text } }
}

private extension UIColor {
    convenience init(argb: UInt32) {
        self.init(red: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255, blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }
}
