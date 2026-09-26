import Combine
import Foundation

enum ImageAPIProvider: String, Codable, CaseIterable, Sendable {
    case openAIImages = "OPENAI_IMAGES"
    case openAIChat = "OPENAI_CHAT"
    case novelAI = "NOVELAI"

    var label: String {
        switch self { case .openAIImages: return "OpenAI Images"; case .openAIChat: return "Chat 端点出图"; case .novelAI: return "NovelAI" }
    }
    var defaultBaseURL: String { self == .novelAI ? "https://image.novelai.net" : "https://api.openai.com/v1" }
    var defaultModel: String { self == .novelAI ? "nai-diffusion-4-5-full" : "gpt-image-1" }
    var sizeOptions: [String] {
        self == .novelAI ? ["832x1216", "1216x832", "1024x1024", "1024x1536", "1536x1024"] : ["1024x1024", "1536x1024", "1024x1536"]
    }
}

struct ImageAPISettings: Codable, Hashable, Sendable {
    var provider: ImageAPIProvider = .openAIImages
    var baseURL = ""
    var model = ""
    var size = ""
    var positivePrompt = ""
    var negativePrompt = ""
    var sampler = "k_euler_ancestral"
    var steps = 28
    var scale = 5.0
    var configured: Bool { !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var effectiveSize: String { size.isEmpty ? provider.sizeOptions[0] : size }
}

@MainActor
final class ImageAPISettingsStore: ObservableObject {
    static let shared = ImageAPISettingsStore()
    static let keyAccount = "standalone-image-api"
    @Published var settings: ImageAPISettings { didSet { save() } }
    @Published var apiKey: String { didSet { KeychainStore.set(apiKey, account: Self.keyAccount) } }
    private let url: URL

    init() {
        let root = (try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory
        url = root.appendingPathComponent("image-api-settings.json")
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(ImageAPISettings.self, from: data) { settings = value }
        else { settings = .init() }
        apiKey = KeychainStore.get(account: Self.keyAccount)
    }

    func switchProvider(_ provider: ImageAPIProvider) {
        guard provider != settings.provider else { return }
        settings.provider = provider; settings.baseURL = provider.defaultBaseURL; settings.model = provider.defaultModel; settings.size = provider.sizeOptions[0]
    }
    private func save() { if let data = try? JSONEncoder().encode(settings) { try? data.write(to: url, options: .atomic) } }
}
