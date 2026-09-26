import SwiftUI

struct TXTImportPreviewView: View {
    let source: TxtImportSource
    var onImport: (ImportedBook) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "auto"
    @State private var selectedRuleId: Int64 = -2
    @State private var customRegex = #"^[ 　\t]{0,4}第\s*[\d零〇一二三四五六七八九十百千万]+\s*[章节回卷部篇].{0,40}$"#
    @State private var aiBusy = false
    @State private var aiAttempt = 0
    @State private var aiProposal: AIChapterRuleProposal?
    @State private var aiError: String?

    private var result: TxtSplitResult {
        if mode == "custom" { return TxtChapterSplitter.split(source.text, customRegex: customRegex) ?? TxtChapterSplitter.chooseBest(source.text) }
        if mode == "rule", let rule = TxtChapterSplitter.rules.first(where: { $0.id == selectedRuleId }) {
            return TxtChapterSplitter.split(source.text, rule: rule) ?? TxtChapterSplitter.chooseBest(source.text)
        }
        return TxtChapterSplitter.chooseBest(source.text)
    }

    var body: some View {
        NavigationStack {
            List {
                splitModeSection
                aiRuleSection
                previewSection
            }
            .navigationTitle("TXT 分章预览")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { importCurrentResult() }
                        .disabled(result.chapters.isEmpty)
                }
            }
        }
    }

    @ViewBuilder private var splitModeSection: some View {
        Section("分章方式") {
            Picker("模式", selection: $mode) {
                Text("自动选择最佳规则").tag("auto")
                Text("选择规则").tag("rule")
                Text("自定义正则").tag("custom")
            }
            if mode == "rule" {
                Picker("规则", selection: $selectedRuleId) {
                    ForEach(TxtChapterSplitter.rules.filter { !$0.rule.isEmpty }) { rule in
                        Text("\(rule.enable ? "✓" : "○") \(rule.name)").tag(rule.id)
                    }
                }
                if let rule = TxtChapterSplitter.rules.first(where: { $0.id == selectedRuleId }) {
                    Text(rule.example).font(.caption).foregroundStyle(.secondary)
                }
            } else if mode == "custom" {
                TextEditor(text: $customRegex).font(.system(.caption, design: .monospaced)).frame(minHeight: 90)
            }
        }
    }

    @ViewBuilder private var aiRuleSection: some View {
        Section("AI 辅助分章") {
            Button { proposeWithAI() } label: {
                HStack {
                    if aiBusy { ProgressView().controlSize(.small) }
                    Text(aiBusy ? "AI 正在探寻规则 · 第 \(aiAttempt)/3 轮" : "让 AI 探寻章节规则")
                }
            }
            .disabled(aiBusy)
            Text("只向模型发送开头/中部/末尾的脱敏行结构，不发送小说正文语义。模型结果会先在本机全文验证，绝不会自动应用。")
                .font(.caption).foregroundStyle(.secondary)
            if let proposal = aiProposal {
                VStack(alignment: .leading, spacing: 7) {
                    Text(proposal.name).font(.headline)
                    Text(proposal.regex).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("本地验证：\(proposal.chapterCount) 章 · \(proposal.reason)").font(.caption).foregroundStyle(.secondary)
                    if !proposal.sampleTitles.isEmpty { Text(proposal.sampleTitles.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary) }
                    Button("使用此规则") { customRegex = proposal.regex; mode = "custom" }
                }
            }
            if let aiError { Text(aiError).font(.caption).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var previewSection: some View {
        Section("预览 · \(result.chapters.count) 章") {
            if result.usedFallback { Text("没有规则达到合理章节数，已按约 1 万字分节兜底。").font(.caption).foregroundStyle(.secondary) }
            if let rule = result.rule { Text("当前：\(rule.name) · 评分 \(Int(result.score.rounded()))").font(.caption).foregroundStyle(.secondary) }
            ForEach(result.chapters.prefix(80)) { chapter in
                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.title)
                    Text("\(chapter.charCount) 字 · \(chapter.content.prefix(80))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if result.chapters.count > 80 { Text("其余 \(result.chapters.count - 80) 章…").foregroundStyle(.secondary) }
        }
    }

    private func importCurrentResult() {
        let book: ImportedBook
        if mode == "custom" {
            book = TextImporter.importedBook(source: source, customPattern: customRegex)
        } else if mode == "rule", let rule = TxtChapterSplitter.rules.first(where: { $0.id == selectedRuleId }) {
            book = TextImporter.importedBook(source: source, selectedRule: rule)
        } else {
            book = TextImporter.importedBook(source: source)
        }
        onImport(book)
        dismiss()
    }

    private func proposeWithAI() {
        guard !aiBusy else { return }
        aiBusy = true; aiAttempt = 0; aiError = nil; aiProposal = nil
        Task { @MainActor in
            do {
                aiProposal = try await AIChapterRuleAgent.propose(text: source.text) { attempt in
                    await MainActor.run { aiAttempt = attempt }
                }
            } catch { aiError = error.localizedDescription }
            aiBusy = false
        }
    }

}
