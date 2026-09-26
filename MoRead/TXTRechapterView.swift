import SwiftUI

struct TXTRechapterView: View {
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @State private var source: TxtImportSource?
    @State private var mode = "auto"
    @State private var selectedRuleId: Int64 = -2
    @State private var customRegex = #"^[ 　\t]{0,4}第\s*[\d零〇一二三四五六七八九十百千万]+\s*[章节回卷部篇].{0,40}$"#
    @State private var loading = true
    @State private var applying = false
    @State private var errorText: String?
    @State private var confirmApply = false
    @State private var aiBusy = false
    @State private var aiAttempt = 0
    @State private var aiProposal: AIChapterRuleProposal?

    private var result: TxtSplitResult? {
        guard let source else { return nil }
        if mode == "custom" { return TxtChapterSplitter.split(source.text, customRegex: customRegex) }
        if mode == "rule", let rule = TxtChapterSplitter.rules.first(where: { $0.id == selectedRuleId }) { return TxtChapterSplitter.split(source.text, rule: rule) }
        return TxtChapterSplitter.chooseBest(source.text)
    }

    var body: some View {
        NavigationStack {
            rechapterContent
                .navigationTitle("重新识别 TXT 章节")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("应用") { confirmApply = true }.disabled(result?.chapters.isEmpty != false || applying) }
                }
                .task { await load() }
                .alert("重新分章会重置阅读位置", isPresented: $confirmApply) {
                    Button("取消", role: .cancel) { }
                    Button("确认应用", role: .destructive) { Task { await apply() } }
                } message: {
                    Text("正文会重新写入 text.mz，并重置阅读进度和向量索引；批注、笔记、统计等个人记录不会被删除，但旧章节坐标可能需要重新定位。")
                }
                .alert("操作失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好", role: .cancel) { } } message: { Text(errorText ?? "") }
        }
    }

    @ViewBuilder private var rechapterContent: some View {
        if loading {
            ProgressView("正在读取原始 TXT…")
        } else if let result {
            List {
                rulesSection
                previewSection(result)
            }
        } else {
            ContentUnavailableView("规则没有识别出章节", systemImage: "text.badge.xmark", description: Text("换一个规则或修改自定义正则。"))
        }
    }

    @ViewBuilder private var rulesSection: some View {
        Section("重新识别规则") {
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
            } else if mode == "custom" {
                TextEditor(text: $customRegex).font(.system(.caption, design: .monospaced)).frame(minHeight: 96)
            }
            Button { Task { await proposeWithAI() } } label: {
                if aiBusy { HStack { ProgressView().controlSize(.small); Text("AI 正在尝试第 \(max(1, aiAttempt)) / 3 次…") } }
                else { Label("AI 探寻章节规则", systemImage: "wand.and.stars") }
            }
            .disabled(aiBusy)
            if let aiProposal {
                VStack(alignment: .leading, spacing: 5) {
                    Text("AI 提案：\(aiProposal.name)").font(.subheadline.bold())
                    Text(aiProposal.reason).font(.caption).foregroundStyle(.secondary)
                    Text("本地全文验证：\(aiProposal.chapterCount) 章 · \(aiProposal.sampleTitles.joined(separator: " / "))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func previewSection(_ result: TxtSplitResult) -> some View {
        Section("预览 · \(result.chapters.count) 章") {
            if result.usedFallback { Text("没有规则达到合理章节数，已按约 1 万字兜底分节。").font(.caption).foregroundStyle(.secondary) }
            if let rule = result.rule { Text("当前：\(rule.name) · 评分 \(Int(result.score.rounded()))").font(.caption).foregroundStyle(.secondary) }
            ForEach(result.chapters.prefix(100)) { c in
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.title)
                    Text("\(c.charCount) 字 · \(c.content.prefix(90))").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if result.chapters.count > 100 { Text("其余 \(result.chapters.count - 100) 章…").foregroundStyle(.secondary) }
        }
    }

    @MainActor private func load() async {
        loading = true; defer { loading = false }
        do { source = try await LibraryRepository.shared.txtSource(bookId: book.id) }
        catch { errorText = error.localizedDescription }
    }

    @MainActor private func proposeWithAI() async {
        guard let source else { return }
        aiBusy = true; aiAttempt = 0; aiProposal = nil
        defer { aiBusy = false }
        do {
            let current = result ?? TxtChapterSplitter.chooseBest(source.text)
            let proposal = try await AIChapterRuleService.propose(text: source.text, current: current) { attempt in
                await MainActor.run { aiAttempt = attempt }
            }
            aiProposal = proposal
            customRegex = proposal.regex
            mode = "custom"
        } catch { errorText = error.localizedDescription }
    }

    @MainActor private func apply() async {
        guard let result else { return }
        applying = true; defer { applying = false }
        do { try await LibraryRepository.shared.replaceTXTChapters(bookId: book.id, split: result); dismiss() }
        catch { errorText = error.localizedDescription }
    }
}
