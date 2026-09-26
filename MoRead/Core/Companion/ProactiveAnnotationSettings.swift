import Combine
import Foundation

struct BookProactiveAnnotationLimits: Codable, Hashable, Sendable {
    var enabled = false
    var limits = ProactiveAnnotationLimits()
}

enum ProactiveAnnotationNoticeMode: String, Codable, CaseIterable, Sendable {
    case off = "OFF"
    case builtIn = "BUILT_IN"
    case fastModel = "FAST_MODEL"

    var label: String {
        switch self { case .off: return "关闭"; case .builtIn: return "免费数量提示"; case .fastModel: return "快速模型角色短句" }
    }
}

struct ProactiveAnnotationPolicy: Hashable, Sendable {
    var enabled: Bool
    var personaIds: [Int64]
    var limits: ProactiveAnnotationLimits
    var voiceEnabled: Bool
    var imagesEnabled: Bool
    var noticeMode: ProactiveAnnotationNoticeMode
}

@MainActor
final class ProactiveAnnotationSettingsStore: ObservableObject {
    static let shared = ProactiveAnnotationSettingsStore()

    @Published var enabled: Bool { didSet { save() } }
    @Published var personaIds: [Int64] { didSet { save() } }
    @Published var voiceEnabled: Bool { didSet { save() } }
    @Published var imagesEnabled: Bool { didSet { save() } }
    @Published var noticeMode: ProactiveAnnotationNoticeMode { didSet { save() } }
    @Published var limits: ProactiveAnnotationLimits { didSet { save() } }
    @Published var perBook: [Int64: BookProactiveAnnotationLimits] { didSet { save() } }

    private let url: URL
    private var saving = false

    private struct Snapshot: Codable {
        var enabled: Bool = false
        var personaIds: [Int64] = []
        var voiceEnabled: Bool = false
        var imagesEnabled: Bool = false
        var noticeMode: ProactiveAnnotationNoticeMode = .builtIn
        var limits: ProactiveAnnotationLimits = .init()
        var perBook: [Int64: BookProactiveAnnotationLimits] = [:]

        private enum CodingKeys: String, CodingKey {
            case enabled, personaIds, voiceEnabled, imagesEnabled, noticeMode, noticesEnabled, limits, perBook
        }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            personaIds = try c.decodeIfPresent([Int64].self, forKey: .personaIds) ?? []
            voiceEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? false
            imagesEnabled = try c.decodeIfPresent(Bool.self, forKey: .imagesEnabled) ?? false
            if let mode = try c.decodeIfPresent(ProactiveAnnotationNoticeMode.self, forKey: .noticeMode) { noticeMode = mode }
            else { noticeMode = (try c.decodeIfPresent(Bool.self, forKey: .noticesEnabled) ?? true) ? .builtIn : .off }
            limits = (try c.decodeIfPresent(ProactiveAnnotationLimits.self, forKey: .limits) ?? .init()).normalized()
            perBook = try c.decodeIfPresent([Int64: BookProactiveAnnotationLimits].self, forKey: .perBook) ?? [:]
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(personaIds, forKey: .personaIds)
            try c.encode(voiceEnabled, forKey: .voiceEnabled)
            try c.encode(imagesEnabled, forKey: .imagesEnabled)
            try c.encode(noticeMode, forKey: .noticeMode)
            try c.encode(limits, forKey: .limits)
            try c.encode(perBook, forKey: .perBook)
        }
    }

    init() {
        let root = (try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory
        url = root.appendingPathComponent("proactive-annotation-settings.json")
        var snapshot = Snapshot()
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Snapshot.self, from: data) { snapshot = saved }
        enabled = snapshot.enabled
        personaIds = Array(Set(snapshot.personaIds.filter { $0 > 0 })).sorted()
        voiceEnabled = snapshot.voiceEnabled
        imagesEnabled = snapshot.imagesEnabled
        noticeMode = snapshot.noticeMode
        limits = snapshot.limits.normalized()
        perBook = snapshot.perBook.filter { $0.key > 0 }.mapValues { .init(enabled: $0.enabled, limits: $0.limits.normalized()) }
    }

    func limits(for bookId: Int64) -> ProactiveAnnotationLimits {
        (perBook[bookId]?.enabled == true ? perBook[bookId]?.limits : limits)?.normalized() ?? limits.normalized()
    }

    func policy(for bookId: Int64) -> ProactiveAnnotationPolicy {
        .init(
            enabled: enabled,
            personaIds: personaIds,
            limits: limits(for: bookId),
            voiceEnabled: voiceEnabled,
            imagesEnabled: imagesEnabled,
            noticeMode: noticeMode
        )
    }

    func setBookOverride(bookId: Int64, enabled: Bool, limits: ProactiveAnnotationLimits? = nil) {
        let current = perBook[bookId] ?? .init(enabled: false, limits: self.limits)
        perBook[bookId] = .init(enabled: enabled, limits: (limits ?? current.limits).normalized())
    }

    private func save() {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        var snapshot = Snapshot()
        snapshot.enabled = enabled
        snapshot.personaIds = Array(Set(personaIds.filter { $0 > 0 })).sorted()
        snapshot.voiceEnabled = voiceEnabled
        snapshot.imagesEnabled = imagesEnabled
        snapshot.noticeMode = noticeMode
        snapshot.limits = limits.normalized()
        snapshot.perBook = perBook.filter { $0.key > 0 }.mapValues { .init(enabled: $0.enabled, limits: $0.limits.normalized()) }
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        NotificationCenter.default.post(name: .proactiveAnnotationPolicyChanged, object: nil)
    }
}
