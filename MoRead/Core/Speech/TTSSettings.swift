import Foundation
import Combine

enum TTSEngineMode: String, Codable, CaseIterable, Sendable { case system = "SYSTEM", ai = "AI" }
enum TTSSynthesisGranularity: String, Codable, CaseIterable, Sendable { case sentence = "SENTENCE", paragraph = "PARAGRAPH", chapter = "CHAPTER" }
enum TTSAPIProvider: String, Codable, CaseIterable, Sendable {
    case minimaxCN = "MINIMAX_CN", minimaxIntl = "MINIMAX_INTL", openAICompatible = "OPENAI_COMPAT", gemini = "GEMINI"
    var defaultBaseURL: String { switch self { case .minimaxCN: "https://api.minimaxi.com/v1"; case .minimaxIntl: "https://api.minimax.io/v1"; case .openAICompatible: "https://api.openai.com/v1"; case .gemini: "https://generativelanguage.googleapis.com/v1beta" } }
    var defaultModel: String { switch self { case .minimaxCN,.minimaxIntl: "speech-2.8-hd"; case .openAICompatible: "gpt-4o-mini-tts"; case .gemini: "gemini-2.5-flash-preview-tts" } }
}

struct TTSSettings: Codable, Equatable, Sendable {
    var engineMode: TTSEngineMode = .system
    var systemLanguageTag = ""
    var systemVoiceIdentifier = ""
    var systemRate: Double = 1
    var systemPitch: Double = 1
    var aiProvider: TTSAPIProvider = .openAICompatible
    var aiBaseURL = "https://api.openai.com/v1"
    var aiModel = "gpt-4o-mini-tts"
    var aiVoiceId = "alloy"
    var aiSpeed: Double = 1
    var aiVolume: Double = 1
    var aiPitch = 0
    var aiGroupId = ""
    var allowAudioMixing = false
    var trimSilence = true
    var synthesisGranularity: TTSSynthesisGranularity = .paragraph
    var maxSynthesisChars = 400
    var synthesisConcurrency = 2
    var retryCount = 2
    var prefetchCount = 3
    var audiobookEnginePolicy = "NARRATOR_SYSTEM_CHARACTERS_AI"
    var configured: Bool { !aiBaseURL.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !aiModel.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
}

@MainActor final class TTSSettingsStore: ObservableObject {
    static let shared = TTSSettingsStore()
    @Published var settings: TTSSettings { didSet { save() } }
    @Published var apiKey: String { didSet { if !apiKey.isEmpty { KeychainStore.set(apiKey, account: keyAlias(settings.aiProvider)) } } }
    private let url: URL
    init() {
        let root=(try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory
        url=root.appendingPathComponent("tts-settings.json")
        settings=(try? Data(contentsOf:url)).flatMap{try? JSONDecoder().decode(TTSSettings.self,from:$0)} ?? TTSSettings()
        apiKey=KeychainStore.get(account:"standalone-tts-api-\(settings.aiProvider.rawValue)")
    }
    func switchProvider(_ provider:TTSAPIProvider){settings.aiProvider=provider;if settings.aiBaseURL.isEmpty || TTSAPIProvider.allCases.map(\.defaultBaseURL).contains(settings.aiBaseURL){settings.aiBaseURL=provider.defaultBaseURL};if settings.aiModel.isEmpty{settings.aiModel=provider.defaultModel};apiKey=KeychainStore.get(account:keyAlias(provider))}
    func keyAlias(_ provider:TTSAPIProvider)->String{"standalone-tts-api-\(provider.rawValue)"}
    func currentKey()->String{apiKey.isEmpty ? KeychainStore.get(account:keyAlias(settings.aiProvider)):apiKey}
    private func save(){try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);if let d=try? JSONEncoder().encode(settings){try? d.write(to:url,options:.atomic)}}
}
