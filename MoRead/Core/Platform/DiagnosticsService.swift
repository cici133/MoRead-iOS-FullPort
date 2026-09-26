import Foundation

struct DiagnosticCheck: Identifiable, Sendable {
    enum Level: String, Sendable { case ok, warning, error }
    var id = UUID()
    var title: String
    var detail: String
    var level: Level
}

struct DiagnosticSnapshot: Sendable {
    var generatedAt: Date
    var checks: [DiagnosticCheck]

    var report: String {
        var lines = ["MoRead iOS 诊断报告", "生成时间：\(generatedAt.formatted())", "数据库 schema：\(MoReadDatabase.schemaVersion)", ""]
        for item in checks { lines.append("[\(item.level.rawValue.uppercased())] \(item.title)\n\(item.detail)\n") }
        lines.append("隐私：本报告不包含 API Key、Authorization、书籍正文、聊天正文或模型响应正文。")
        return lines.joined(separator: "\n")
    }
}

actor DiagnosticsService {
    static let shared = DiagnosticsService()

    func run() async -> DiagnosticSnapshot {
        var checks: [DiagnosticCheck] = []
        do {
            let rows = try await MoReadDatabase.shared.rows("PRAGMA integrity_check")
            let result = rows.first?.values.first?.string ?? "unknown"
            checks.append(.init(title: "数据库完整性", detail: result, level: result.lowercased() == "ok" ? .ok : .error))
        } catch { checks.append(.init(title: "数据库完整性", detail: error.localizedDescription, level: .error)) }

        do {
            let root = try MoReadDatabase.applicationDirectory()
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: root.path)
            let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            checks.append(.init(title: "应用数据目录", detail: "\(root.path)\n可用空间：\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))", level: free > 200 * 1024 * 1024 ? .ok : .warning))
        } catch { checks.append(.init(title: "应用数据目录", detail: error.localizedDescription, level: .error)) }

        do {
            let bookCount = try await scalar("SELECT COUNT(*) AS n FROM books")
            let chapterCount = try await scalar("SELECT COUNT(*) AS n FROM chapters")
            let conversationCount = try await scalar("SELECT COUNT(*) AS n FROM conversations")
            let annotationCount = try await scalar("SELECT COUNT(*) AS n FROM annotations")
            checks.append(.init(title: "本地记录", detail: "书籍 \(bookCount) · 章节 \(chapterCount) · 会话 \(conversationCount) · 批注 \(annotationCount)", level: .ok))
        } catch { checks.append(.init(title: "本地记录", detail: error.localizedDescription, level: .warning)) }

        do {
            let providers = try await scalar("SELECT COUNT(*) AS n FROM ai_providers")
            let models = try await scalar("SELECT COUNT(*) AS n FROM ai_models")
            let assigned = try await scalar("SELECT COUNT(*) AS n FROM model_assignments WHERE modelId IS NOT NULL")
            checks.append(.init(title: "AI 配置", detail: "供应商 \(providers) · 模型 \(models) · 已分配角色 \(assigned)", level: providers > 0 && models > 0 ? .ok : .warning))
        } catch { checks.append(.init(title: "AI 配置", detail: error.localizedDescription, level: .warning)) }

        let backup = await MainActor.run { BackupSettingsStore.shared.settings }
        checks.append(.init(title: "WebDAV 自动备份", detail: backup.autoBackup ? "已开启；iOS 会使用 BGProcessingTask，由系统决定实际执行时间。" : "未开启", level: backup.autoBackup ? .ok : .warning))

        let tts = await MainActor.run { TTSSettingsStore.shared.settings }
        checks.append(.init(title: "朗读", detail: tts.engineMode == .system ? "系统 TTS" : "云 TTS · \(tts.aiProvider.rawValue) · \(tts.aiModel)", level: .ok))

        let image = await MainActor.run { ImageAPISettingsStore.shared.settings }
        checks.append(.init(title: "生图", detail: image.configured ? "\(image.provider.label) · \(image.model)" : "未配置独立生图服务；可继续使用模型分配。", level: image.configured ? .ok : .warning))

        let web = await MainActor.run { WebSearchSettingsStore.shared.settings }
        checks.append(.init(title: "联网搜索", detail: web.enabled ? "已开启 · \(web.provider.label)" : "未开启", level: .ok))

        return .init(generatedAt: Date(), checks: checks)
    }

    private func scalar(_ sql: String) async throws -> Int64 {
        let rows = try await MoReadDatabase.shared.rows(sql)
        return rows.first?["n"]?.int64 ?? 0
    }
}
