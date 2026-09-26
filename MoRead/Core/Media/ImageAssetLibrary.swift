import CryptoKit
import Foundation
import UIKit

struct ImageAssetRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var filePath: String
    var sha256: String
    var createdAt: Int64
    var purpose: String?

    var effectivePurpose: String { purpose?.isEmpty == false ? purpose! : "未分类" }
}

actor ImageAssetLibrary {
    static let shared = ImageAssetLibrary()
    private let encoder = JSONEncoder(), decoder = JSONDecoder()

    func list() throws -> [ImageAssetRecord] {
        guard let data = try? Data(contentsOf: manifestURL()), let values = try? decoder.decode([ImageAssetRecord].self, from: data) else { return [] }
        return values.filter { FileManager.default.fileExists(atPath: $0.filePath) }.sorted { $0.createdAt > $1.createdAt }
    }

    func asset(id: String) throws -> ImageAssetRecord? { try list().first { $0.id == id } }

    @discardableResult
    func importImage(from source: URL, name: String? = nil) throws -> ImageAssetRecord {
        let scoped = source.startAccessingSecurityScopedResource(); defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard (1...(40 * 1024 * 1024)).contains(data.count), let image = UIImage(data: data) else { throw ImageGenerationError.invalidResponse("参考图无效或超过 40 MB") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = try list().first(where: { $0.sha256 == hash }) { return existing }
        let root = try rootURL(); let id = UUID().uuidString
        let target = root.appendingPathComponent("\(id).jpg")
        let normalized = try Self.normalizedJPEG(image)
        try normalized.write(to: target, options: .atomic)
        let item = ImageAssetRecord(id: id, name: name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? source.deletingPathExtension().lastPathComponent, filePath: target.path, sha256: hash, createdAt: Self.now(), purpose: nil)
        var values = try list(); values.append(item); try save(values); return item
    }


    func update(id: String, name: String? = nil, purpose: String? = nil) throws {
        var values = try list()
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        if let name {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { values[index].name = String(clean.prefix(120)) }
        }
        if let purpose { values[index].purpose = purpose }
        try save(values)
    }

    func references(id: String) async throws -> [String] {
        guard let item = try asset(id: id) else { return [] }
        var uses: [String] = []
        let root = try MoReadDatabase.applicationDirectory()
        let needles = [item.filePath, "asset:\(id)", "\"\(id)\""]

        // Reader theme/title presets are file-backed settings. Read them directly so this actor
        // never needs to cross into a @MainActor settings singleton.
        for (file, label) in [("reader-settings.json", "阅读背景"), ("reader-enhancements.json", "章首样式")] {
            let url = root.appendingPathComponent(file)
            if let raw = try? String(contentsOf: url), needles.contains(where: raw.contains) { uses.append(label) }
        }

        // Review share templates live in UserDefaults and may reference image-library assets from CSS.
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "moread.review.share.templates.v1"), needles.contains(where: raw.contains) {
            uses.append("回顾分享模板")
        } else if let data = defaults.data(forKey: "moread.review.share.templates.v1"),
                  let raw = String(data: data, encoding: .utf8), needles.contains(where: raw.contains) {
            uses.append("回顾分享模板")
        }

        let db = MoReadDatabase.shared
        let direct = try await db.rows("SELECT title FROM books WHERE coverPath=? LIMIT 5", [.text(item.filePath)])
        if !direct.isEmpty { uses.append("书籍封面") }
        let avatars = try await db.rows("SELECT name FROM personas WHERE avatarPath=? LIMIT 5", [.text(item.filePath)])
        if !avatars.isEmpty { uses.append("角色头像") }

        // Image consistency records store stable image-library IDs inside JSON snapshots.
        let like = "%\"\(id)\"%"
        if (try await db.scalarInt("SELECT COUNT(*) FROM book_image_styles WHERE specJson LIKE ?", [.text(like)]) ?? 0) > 0 { uses.append("本书画风") }
        if (try await db.scalarInt("SELECT COUNT(*) FROM image_style_templates WHERE specJson LIKE ?", [.text(like)]) ?? 0) > 0 { uses.append("画风模板") }
        if (try await db.scalarInt("SELECT COUNT(*) FROM character_looks WHERE specJson LIKE ?", [.text(like)]) ?? 0) > 0 { uses.append("人物形象") }
        return Array(Set(uses)).sorted()
    }

    func delete(id: String) async throws {
        var values = try list(); guard let item = values.first(where: { $0.id == id }) else { return }
        let uses = try await references(id: id)
        guard uses.isEmpty else { throw ImageAssetLibraryError.inUse(uses) }
        try FileManager.default.removeItem(atPath: item.filePath)
        values.removeAll { $0.id == id }
        try save(values)
    }

    func normalizedData(id: String, preciseCharacter: Bool = false) throws -> Data {
        guard let item = try asset(id: id), let image = UIImage(contentsOfFile: item.filePath) else { throw ImageGenerationError.invalidResponse("参考图已移除") }
        let maxSide: CGFloat = preciseCharacter ? 1536 : 1536
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let canvas: CGSize
        if preciseCharacter {
            let ratio = size.width / max(1, size.height)
            canvas = ratio < 0.85 ? CGSize(width: 1024, height: 1536) : (ratio > 1.18 ? CGSize(width: 1536, height: 1024) : CGSize(width: 1472, height: 1472))
        } else { canvas = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale)) }
        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.jpegData(withCompressionQuality: 0.94) { ctx in
            (preciseCharacter ? UIColor.black : UIColor.white).setFill(); ctx.fill(CGRect(origin: .zero, size: canvas))
            let fit = min(canvas.width / size.width, canvas.height / size.height)
            let rect = CGRect(x: (canvas.width - size.width * fit)/2, y: (canvas.height - size.height * fit)/2, width: size.width * fit, height: size.height * fit)
            image.draw(in: rect)
        }
    }

    private func rootURL() throws -> URL { let u = try MoReadDatabase.applicationDirectory().appendingPathComponent("image-library", isDirectory: true); try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }
    private func manifestURL() throws -> URL { try rootURL().appendingPathComponent("assets.json") }
    private func save(_ values: [ImageAssetRecord]) throws { try encoder.encode(values).write(to: manifestURL(), options: .atomic) }
    private static func normalizedJPEG(_ image: UIImage) throws -> Data { guard let data = image.jpegData(compressionQuality: 0.94) else { throw ImageGenerationError.invalidResponse("无法保存参考图") }; return data }
    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }


enum ImageAssetLibraryError: LocalizedError {
    case inUse([String])
    var errorDescription: String? {
        switch self {
        case .inUse(let uses): return "这张图片仍被以下位置使用：\(uses.joined(separator: "、"))。请先移除这些引用，再删除图片。"
        }
    }
}
