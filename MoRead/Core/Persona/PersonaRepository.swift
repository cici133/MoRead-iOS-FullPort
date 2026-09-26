import Foundation

struct PersonaExampleDialog: Codable, Hashable, Sendable {
    var user: String
    var assistant: String
}

struct PersonaLoreEntry: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var content: String
    var enabled: Bool = true
    var constant: Bool = false
    var keys: [String] = []
}

struct PersonaRecord: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var avatarPath: String?
    var subtitle: String
    var personality: String
    var speakingStyle: String
    var greeting: String
    var exampleDialogs: [PersonaExampleDialog]
    var isRoleplay: Bool
    var enabledTools: [String]
    var worldBook: [PersonaLoreEntry]
    var worldBookEnabled: Bool
    var chatModelId: Int64?
    var userProfile: String
    var memoryEnabled: Bool
    var chatAppearanceJSON: String
    var voiceId: String
    var voiceEmotion: String
    var isBuiltIn: Bool
    var createdAt: Int64
}

struct PersonaDraft: Sendable {
    var id: Int64 = 0
    var name: String
    var avatarPath: String? = nil
    var subtitle: String = ""
    var personality: String = ""
    var speakingStyle: String = ""
    var greeting: String = ""
    var exampleDialogs: [PersonaExampleDialog] = []
    var isRoleplay: Bool = false
    var enabledTools: [String] = ["search_book", "grep_book", "read_chapter", "list_annotations", "list_notes", "add_note"]
    var worldBook: [PersonaLoreEntry] = []
    var worldBookEnabled = true
    var chatModelId: Int64? = nil
    var userProfile = ""
    var memoryEnabled = true
    var chatAppearanceJSON = "{}"
    var voiceId = ""
    var voiceEmotion = ""
}

actor PersonaRepository {
    static let shared = PersonaRepository()
    private let db = MoReadDatabase.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func personas() async throws -> [PersonaRecord] {
        try await seedIfNeeded()
        return try await db.rows("SELECT * FROM personas ORDER BY isBuiltIn DESC, createdAt, id").compactMap(Self.row)
    }

    func persona(id: Int64) async throws -> PersonaRecord? {
        try await db.rows("SELECT * FROM personas WHERE id=?", [.integer(id)]).first.flatMap(Self.row)
    }

    @discardableResult
    func save(_ draft: PersonaDraft) async throws -> Int64 {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PersonaError.invalid("角色名称不能为空") }
        let examples = String(data: try encoder.encode(draft.exampleDialogs), encoding: .utf8) ?? "[]"
        let lore = String(data: try encoder.encode(draft.worldBook), encoding: .utf8) ?? "[]"
        let toolsData = try JSONSerialization.data(withJSONObject: draft.enabledTools)
        let tools = String(data: toolsData, encoding: .utf8) ?? "[]"
        if draft.id == 0 {
            let now = Self.now()
            return try await db.execute("""
            INSERT INTO personas(name,avatarPath,subtitle,personality,speakingStyle,greeting,exampleDialogsJson,isRoleplay,enabledToolsJson,worldBookJson,worldBookEnabled,chatModelId,userProfile,memoryEnabled,chatAppearanceJson,voiceId,voiceEmotion,isBuiltIn,createdAt)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(name), draft.avatarPath.map(SQLValue.text) ?? .null, .text(draft.subtitle), .text(draft.personality),
                .text(draft.speakingStyle), .text(draft.greeting), .text(examples), .integer(draft.isRoleplay ? 1 : 0),
                .text(tools), .text(lore), .integer(draft.worldBookEnabled ? 1 : 0), draft.chatModelId.map(SQLValue.integer) ?? .null,
                .text(draft.userProfile), .integer(draft.memoryEnabled ? 1 : 0), .text(draft.chatAppearanceJSON), .text(draft.voiceId),
                .text(draft.voiceEmotion), .integer(0), .integer(now)
            ])
        }
        guard let existing = try await persona(id: draft.id) else { throw PersonaError.invalid("角色不存在") }
        try await db.execute("""
        UPDATE personas SET name=?,avatarPath=?,subtitle=?,personality=?,speakingStyle=?,greeting=?,exampleDialogsJson=?,isRoleplay=?,enabledToolsJson=?,worldBookJson=?,worldBookEnabled=?,chatModelId=?,userProfile=?,memoryEnabled=?,chatAppearanceJson=?,voiceId=?,voiceEmotion=? WHERE id=?
        """, [
            .text(name), draft.avatarPath.map(SQLValue.text) ?? .null, .text(draft.subtitle), .text(draft.personality),
            .text(draft.speakingStyle), .text(draft.greeting), .text(examples), .integer(draft.isRoleplay ? 1 : 0),
            .text(tools), .text(lore), .integer(draft.worldBookEnabled ? 1 : 0), draft.chatModelId.map(SQLValue.integer) ?? .null,
            .text(draft.userProfile), .integer(draft.memoryEnabled ? 1 : 0), .text(draft.chatAppearanceJSON), .text(draft.voiceId), .text(draft.voiceEmotion), .integer(draft.id)
        ])
        if existing.avatarPath != draft.avatarPath, let old = existing.avatarPath { try? FileManager.default.removeItem(atPath: old) }
        return draft.id
    }

    func importAvatar(from source: URL) async throws -> String {
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard (1...(20 * 1024 * 1024)).contains(data.count) else { throw PersonaError.invalid("头像为空或超过 20 MB") }
        let root = try MoReadDatabase.applicationDirectory().appendingPathComponent("avatars", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ext = ["png","jpg","jpeg","webp"].contains(source.pathExtension.lowercased()) ? source.pathExtension.lowercased() : "png"
        let target = root.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: target, options: .atomic)
        return target.path
    }

    func delete(id: Int64) async throws {
        let existing = try await persona(id: id)
        try await db.execute("DELETE FROM personas WHERE id=?", [.integer(id)])
        if let path = existing?.avatarPath { try? FileManager.default.removeItem(atPath: path) }
    }

    func importCard(data: Data, filename: String) async throws -> Int64 {
        guard let card = SillyTavernCardParser.parse(data) else { throw PersonaError.invalid("不是可识别的 SillyTavern 角色卡") }
        var avatarPath: String?
        if let avatar = card.avatarPNG {
            let root = try MoReadDatabase.applicationDirectory().appendingPathComponent("avatars", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let target = root.appendingPathComponent("\(UUID().uuidString).png")
            try avatar.write(to: target, options: .atomic)
            avatarPath = target.path
        }
        return try await save(.init(
            name: card.name, avatarPath: avatarPath, subtitle: card.subtitle, personality: card.personality,
            speakingStyle: card.speakingStyle, greeting: card.greeting, exampleDialogs: card.exampleDialogs,
            isRoleplay: false, worldBook: card.worldBook, worldBookEnabled: true
        ))
    }

    func systemPrompt(for persona: PersonaRecord?, triggerText: String = "", includeUserProfile: Bool = true) -> String {
        guard let persona else {
            return "你是墨知阅读伴读。围绕用户正在阅读的本地书籍回答，引用原文时必须以工具返回的内容为准，不要猜测未读取的后文。"
        }
        var blocks: [String] = []
        if persona.isRoleplay {
            blocks.append("你正在扮演 \(persona.name)。保持角色身份与说话方式，但不要替用户决定其言行。")
        } else {
            blocks.append("你是以「\(persona.name)」这套表达偏好工作的阅读助手。角色资料用于语气、关注点和交流方式，不要求虚构自己真的经历过角色设定中的事件。")
        }
        if !persona.subtitle.isEmpty { blocks.append("【定位】\n\(persona.subtitle)") }
        if !persona.personality.isEmpty { blocks.append("【人设】\n\(persona.personality)") }
        if !persona.speakingStyle.isEmpty { blocks.append("【说话风格】\n\(persona.speakingStyle)") }
        if includeUserProfile && !persona.userProfile.isEmpty { blocks.append("【你已了解的用户信息】\n\(persona.userProfile)") }
        if persona.worldBookEnabled {
            let lower = triggerText.lowercased()
            let selected = persona.worldBook.filter { entry in
                entry.enabled && (entry.constant || entry.keys.contains { key in !key.isEmpty && lower.contains(key.lowercased()) })
            }
            if !selected.isEmpty { blocks.append("【设定集】\n" + selected.map { "\($0.name)：\($0.content)" }.joined(separator: "\n")) }
        }
        if !persona.exampleDialogs.isEmpty {
            blocks.append("【示例对话】\n" + persona.exampleDialogs.prefix(4).map { "用户：\($0.user)\n\(persona.name)：\($0.assistant)" }.joined(separator: "\n\n"))
        }
        if !persona.greeting.isEmpty { blocks.append("【开场风格参考】\n\(persona.greeting)") }
        blocks.append("你和用户都在书外一起阅读。正文中的人物、第一/第二人称和经历都属于作品，不能当作用户本人。")
        return blocks.joined(separator: "\n\n")
    }

    func updateUserProfile(personaId: Int64, profile: String) async throws {
        let clean = String(profile.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6_000))
        try await db.execute("UPDATE personas SET userProfile=? WHERE id=?", [.text(clean), .integer(personaId)])
    }

    private func seedIfNeeded() async throws {
        let count = try await db.scalarInt("SELECT COUNT(*) FROM personas") ?? 0
        guard count == 0 else { return }
        let now = Self.now()
        try await db.execute("""
        INSERT INTO personas(name,avatarPath,subtitle,personality,speakingStyle,greeting,exampleDialogsJson,isRoleplay,enabledToolsJson,worldBookJson,worldBookEnabled,chatModelId,userProfile,memoryEnabled,chatAppearanceJson,voiceId,voiceEmotion,isBuiltIn,createdAt)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [
            .text("阿翎"), .null, .text("默认伴读"), .text("细心、好奇，愿意围绕原文和用户一起讨论。"),
            .text("自然、克制、有依据；不剧透。"), .text("一起读吧。"), .text("[]"), .integer(0),
            .text("[\"search_book\",\"grep_book\",\"read_chapter\",\"list_annotations\",\"list_notes\",\"add_note\"]"),
            .text("[]"), .integer(1), .null, .text(""), .integer(1), .text("{}"), .text(""), .text(""), .integer(1), .integer(now)
        ])
    }

    private static func row(_ r: [String: SQLValue]) -> PersonaRecord? {
        guard let id = r["id"]?.int64 else { return nil }
        func decode<T: Decodable>(_ type: T.Type, _ raw: String?, fallback: T) -> T {
            guard let raw, let data = raw.data(using: .utf8) else { return fallback }
            return (try? JSONDecoder().decode(type, from: data)) ?? fallback
        }
        let tools: [String] = {
            guard let raw = r["enabledToolsJson"]?.string, let data = raw.data(using: .utf8) else { return [] }
            return (try? JSONSerialization.jsonObject(with: data) as? [String]) ?? []
        }()
        let examples: [PersonaExampleDialog] = decode([PersonaExampleDialog].self, r["exampleDialogsJson"]?.string, fallback: [])
        let worldBook: [PersonaLoreEntry] = decode([PersonaLoreEntry].self, r["worldBookJson"]?.string, fallback: [])
        let isRoleplay = (r["isRoleplay"]?.int64 ?? 0) != 0
        let worldBookEnabled = (r["worldBookEnabled"]?.int64 ?? 1) != 0
        let memoryEnabled = (r["memoryEnabled"]?.int64 ?? 1) != 0
        let isBuiltIn = (r["isBuiltIn"]?.int64 ?? 0) != 0
        return .init(
            id: id, name: r["name"]?.string ?? "", avatarPath: r["avatarPath"]?.string,
            subtitle: r["subtitle"]?.string ?? "", personality: r["personality"]?.string ?? "",
            speakingStyle: r["speakingStyle"]?.string ?? "", greeting: r["greeting"]?.string ?? "",
            exampleDialogs: examples, isRoleplay: isRoleplay, enabledTools: tools, worldBook: worldBook,
            worldBookEnabled: worldBookEnabled, chatModelId: r["chatModelId"]?.int64,
            userProfile: r["userProfile"]?.string ?? "", memoryEnabled: memoryEnabled,
            chatAppearanceJSON: r["chatAppearanceJson"]?.string ?? "{}", voiceId: r["voiceId"]?.string ?? "",
            voiceEmotion: r["voiceEmotion"]?.string ?? "", isBuiltIn: isBuiltIn,
            createdAt: r["createdAt"]?.int64 ?? 0)
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

enum PersonaError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let text): text } }
}
