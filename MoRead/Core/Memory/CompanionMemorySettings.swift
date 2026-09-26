import Combine
import Foundation

struct CompanionMemorySettings: Codable, Equatable, Sendable {
    var longTermEnabled = true
    var crossBookEnabled = false
    var crossBookChatSearch = false
}

@MainActor final class CompanionMemorySettingsStore: ObservableObject {
    static let shared = CompanionMemorySettingsStore()
    @Published var settings: CompanionMemorySettings { didSet { save() } }
    private let url: URL
    private init() {
        let root = (try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory
        url = root.appendingPathComponent("companion-memory-settings.json")
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(CompanionMemorySettings.self, from: data) { settings = value }
        else { settings = .init() }
    }
    private func save() { if let data = try? JSONEncoder().encode(settings) { try? data.write(to: url, options: .atomic) } }
}
