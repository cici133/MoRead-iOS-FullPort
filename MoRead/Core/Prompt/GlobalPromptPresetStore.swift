import Foundation

enum GlobalPromptInjectionPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case beforeSystem = "BEFORE_SYSTEM"
    case afterSystem = "AFTER_SYSTEM"
    case beforeLastUser = "BEFORE_LAST_USER"
    case afterLastUser = "AFTER_LAST_USER"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .beforeSystem: return "System 之前"
        case .afterSystem: return "System 之后"
        case .beforeLastUser: return "最新用户消息之前"
        case .afterLastUser: return "最新用户消息之后"
        }
    }
}

struct GlobalPromptPreset: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var prompt: String
    var enabled = false
    var position: GlobalPromptInjectionPosition = .afterSystem
    var builtIn = false
}

@MainActor
final class GlobalPromptPresetStore: ObservableObject {
    static let shared = GlobalPromptPresetStore()
    @Published private(set) var presets: [GlobalPromptPreset]
    private let url: URL

    private static let defaults: [GlobalPromptPreset] = [
        .init(id: "builtin-natural-style", name: "自然表达", prompt: "使用自然、具体、连贯的中文回答，避免空泛套话和不必要的重复总结。", position: .afterSystem, builtIn: true),
        .init(id: "builtin-immersive-roleplay", name: "沉浸式角色扮演", prompt: "保持角色视角与说话方式，通过动作、语气和细节增强沉浸感；不要代替用户决定其言行。", position: .afterSystem, builtIn: true),
        .init(id: "builtin-concise", name: "简洁回答", prompt: "优先直接回答问题；除非用户要求展开，否则控制篇幅并省略重复背景。", position: .beforeLastUser, builtIn: true)
    ]

    private init() {
        let root = (try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory
        url = root.appendingPathComponent("global-prompt-presets.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([GlobalPromptPreset].self, from: data) { presets = decoded }
        else { presets = Self.defaults }
    }

    func upsert(_ preset: GlobalPromptPreset) throws {
        var value = preset
        if value.id.isEmpty { value.id = UUID().uuidString }
        value.name = String(value.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        value.prompt = String(value.prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12_000))
        guard !value.name.isEmpty else { throw GlobalPromptError.invalidName }
        guard !value.prompt.isEmpty else { throw GlobalPromptError.invalidPrompt }
        if let index = presets.firstIndex(where: { $0.id == value.id }) { presets[index] = value }
        else { presets.append(value) }
        persist()
    }

    func setEnabled(id: String, enabled: Bool) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].enabled = enabled; persist()
    }

    func delete(_ id: String) { presets.removeAll { $0.id == id }; persist() }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) { try? data.write(to: url, options: .atomic) }
    }
}

enum GlobalPromptError: LocalizedError {
    case invalidName, invalidPrompt
    var errorDescription: String? { self == .invalidName ? "预设名称不能为空" : "提示词不能为空" }
}

enum GlobalPromptInjector {
    static func inject(messages: [AIChatMessage], presets: [GlobalPromptPreset], label: String = "全局预设") -> [AIChatMessage] {
        let enabled = presets.filter { $0.enabled && !$0.prompt.isEmpty }
        guard !enabled.isEmpty else { return messages }
        var output = messages
        func block(_ position: GlobalPromptInjectionPosition) -> String {
            enabled.filter { $0.position == position }.map { "【\(label)·\($0.name)】\n\($0.prompt)" }.joined(separator: "\n")
        }
        let beforeSystem = block(.beforeSystem), afterSystem = block(.afterSystem)
        if !beforeSystem.isEmpty || !afterSystem.isEmpty {
            if let index = output.firstIndex(where: { $0.role == .system }) {
                let old = output[index]
                output[index] = .init(role: .system, content: [beforeSystem, old.content, afterSystem].filter { !$0.isEmpty }.joined(separator: "\n\n"), toolCalls: old.toolCalls, toolCallId: old.toolCallId, parts: old.parts)
            } else {
                output.insert(.init(role: .system, content: [beforeSystem, afterSystem].filter { !$0.isEmpty }.joined(separator: "\n\n")), at: 0)
            }
        }
        let beforeUser = block(.beforeLastUser), afterUser = block(.afterLastUser)
        if let index = output.lastIndex(where: { $0.role == .user }), !beforeUser.isEmpty || !afterUser.isEmpty {
            let old = output[index]
            var parts = old.parts
            if !parts.isEmpty {
                if !beforeUser.isEmpty { parts.insert(.text(beforeUser + "\n\n"), at: 0) }
                if !afterUser.isEmpty { parts.append(.text("\n\n" + afterUser)) }
            }
            output[index] = .init(role: .user, content: [beforeUser, old.content, afterUser].filter { !$0.isEmpty }.joined(separator: "\n\n"), toolCalls: old.toolCalls, toolCallId: old.toolCallId, parts: parts)
        }
        return output
    }
}
