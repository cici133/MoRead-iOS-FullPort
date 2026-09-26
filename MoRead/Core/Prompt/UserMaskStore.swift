import Foundation

struct UserMask: Codable, Identifiable, Equatable, Sendable {
    var id: Int64 = 0
    var name: String = ""
    var description: String = ""
}

struct UserMaskSettings: Codable, Equatable, Sendable {
    var enabled = false
    var activeMaskId: Int64?
    var masks: [UserMask] = []

    var activeMask: UserMask? {
        guard enabled, let activeMaskId else { return nil }
        return masks.first { $0.id == activeMaskId }
    }
}

@MainActor
final class UserMaskStore: ObservableObject {
    static let shared = UserMaskStore()
    @Published private(set) var settings = UserMaskSettings()
    private let url: URL

    private init() {
        let root = (try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory
        url = root.appendingPathComponent("user-masks.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(UserMaskSettings.self, from: data) {
            settings = decoded
        }
    }

    func setEnabled(_ enabled: Bool) {
        settings.enabled = enabled && !settings.masks.isEmpty
        persist()
    }

    func select(_ id: Int64) {
        guard settings.masks.contains(where: { $0.id == id }) else { return }
        settings.activeMaskId = id
        persist()
    }

    @discardableResult
    func save(_ mask: UserMask) throws -> Int64 {
        var value = mask
        if value.id == 0 { value.id = (settings.masks.map(\.id).max() ?? 0) + 1 }
        value.name = String(value.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        value.description = String(value.description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !value.name.isEmpty else { throw UserMaskError.invalidName }
        if let index = settings.masks.firstIndex(where: { $0.id == value.id }) { settings.masks[index] = value }
        else { settings.masks.append(value) }
        if settings.activeMaskId == nil { settings.activeMaskId = value.id }
        persist(); return value.id
    }

    func delete(_ id: Int64) {
        settings.masks.removeAll { $0.id == id }
        if settings.activeMaskId == id { settings.activeMaskId = settings.masks.first?.id }
        if settings.masks.isEmpty { settings.enabled = false }
        persist()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(settings) { try? data.write(to: url, options: .atomic) }
    }
}

enum UserMaskError: LocalizedError {
    case invalidName
    var errorDescription: String? { "用户面具名称不能为空" }
}
