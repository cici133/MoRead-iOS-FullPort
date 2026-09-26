import Combine
import Foundation

@MainActor final class CompanionAutonomySettingsStore: ObservableObject {
    static let shared = CompanionAutonomySettingsStore()

    @Published var voiceRepliesEnabled: Bool { didSet { save() } }
    @Published var imageRepliesEnabled: Bool { didSet { save() } }
    @Published var multiBubbleReplies: Bool { didSet { save() } }
    @Published var showTokenUsage: Bool { didSet { save() } }
    @Published var showAIAnnotations: Bool { didSet { save() } }
    @Published var spoilerProtectionEnabled: Bool { didSet { save() } }
    /// When enabled, an assistant turn finishing triggers one bounded suggestion-model call.
    /// Default is off because this is an optional paid convenience feature.
    @Published var suggestionRepliesEnabled: Bool { didSet { save() } }

    private let url: URL

    private struct Snapshot: Codable {
        var voiceRepliesEnabled: Bool
        var imageRepliesEnabled: Bool
        var multiBubbleReplies: Bool
        var showTokenUsage: Bool
        var showAIAnnotations: Bool
        var spoilerProtectionEnabled: Bool
        var suggestionRepliesEnabled: Bool

        init(
            voiceRepliesEnabled: Bool = false,
            imageRepliesEnabled: Bool = false,
            multiBubbleReplies: Bool = false,
            showTokenUsage: Bool = false,
            showAIAnnotations: Bool = true,
            spoilerProtectionEnabled: Bool = true,
            suggestionRepliesEnabled: Bool = true
        ) {
            self.voiceRepliesEnabled = voiceRepliesEnabled
            self.imageRepliesEnabled = imageRepliesEnabled
            self.multiBubbleReplies = multiBubbleReplies
            self.showTokenUsage = showTokenUsage
            self.showAIAnnotations = showAIAnnotations
            self.spoilerProtectionEnabled = spoilerProtectionEnabled
            self.suggestionRepliesEnabled = suggestionRepliesEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case voiceRepliesEnabled, imageRepliesEnabled, multiBubbleReplies, showTokenUsage, showAIAnnotations, spoilerProtectionEnabled, suggestionRepliesEnabled
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            voiceRepliesEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceRepliesEnabled) ?? false
            imageRepliesEnabled = try c.decodeIfPresent(Bool.self, forKey: .imageRepliesEnabled) ?? false
            multiBubbleReplies = try c.decodeIfPresent(Bool.self, forKey: .multiBubbleReplies) ?? false
            showTokenUsage = try c.decodeIfPresent(Bool.self, forKey: .showTokenUsage) ?? false
            showAIAnnotations = try c.decodeIfPresent(Bool.self, forKey: .showAIAnnotations) ?? true
            spoilerProtectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .spoilerProtectionEnabled) ?? true
            suggestionRepliesEnabled = try c.decodeIfPresent(Bool.self, forKey: .suggestionRepliesEnabled) ?? true
        }
    }

    init() {
        let root = (try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory
        url = root.appendingPathComponent("companion-autonomy.json")
        let snapshot = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
        voiceRepliesEnabled = snapshot.voiceRepliesEnabled
        imageRepliesEnabled = snapshot.imageRepliesEnabled
        multiBubbleReplies = snapshot.multiBubbleReplies
        showTokenUsage = snapshot.showTokenUsage
        showAIAnnotations = snapshot.showAIAnnotations
        spoilerProtectionEnabled = snapshot.spoilerProtectionEnabled
        suggestionRepliesEnabled = snapshot.suggestionRepliesEnabled
    }

    private func save() {
        let snapshot = Snapshot(
            voiceRepliesEnabled: voiceRepliesEnabled,
            imageRepliesEnabled: imageRepliesEnabled,
            multiBubbleReplies: multiBubbleReplies,
            showTokenUsage: showTokenUsage,
            showAIAnnotations: showAIAnnotations,
            spoilerProtectionEnabled: spoilerProtectionEnabled,
            suggestionRepliesEnabled: suggestionRepliesEnabled
        )
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
}
