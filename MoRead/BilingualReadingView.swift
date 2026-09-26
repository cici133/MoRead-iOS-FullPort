import SwiftUI

struct BilingualReadingView: View {
    @Environment(\.dismiss) private var dismiss
    let bookId: Int64
    let chapterIndex: Int
    let sourceText: String
    @ObservedObject var controller: ReaderWebController
    @ObservedObject var settings: ReaderSettingsStore
    var onChanged: ([ParagraphTranslationRecord]) -> Void

    @State private var rows: [ParagraphTranslationRecord] = []
    @State private var replaceCached = false
    @State private var busy = false
    @State private var done = 0
    @State private var total = 0
    @State private var status = ""
    @State private var errorText: String?
    @State private var work: Task<Void, Never>?

    private var visible: Bool { settings.bilingualVisible(bookId: bookId) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("在英文段落下显示译文", isOn: Binding(
                        get: { visible },
                        set: { value in
                            settings.setBilingualVisible(value, bookId: bookId)
                            onChanged(rows)
                        }
                    ))
                    Text("隐藏后保留缓存，开关只作用于本书。译文是显示层，不修改原始正文。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("批量翻译") {
                    Button("翻译当前页") { start(.page) }.disabled(busy)
                    Button("翻译当前章") { start(.chapter) }.disabled(busy)
                    Toggle("重新翻译已有段落", isOn: $replaceCached).disabled(busy)
                    if busy {
                        ProgressView(value: Double(done), total: Double(max(1, total)))
                        HStack {
                            Text("\(done) / \(total) 段").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("停止", role: .destructive) { work?.cancel() }
                        }
                    }
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                }

                Section("本章译文缓存") {
                    if rows.isEmpty {
                        ContentUnavailableView("还没有译文", systemImage: "character.book.closed", description: Text("可翻译当前页、当前章，或在正文中选中一段后点“翻译”。"))
                    } else {
                        ForEach(rows, id: \.stableID) { row in
                            TranslationCacheRow(
                                row: row,
                                source: sourceSnippet(row),
                                busy: busy,
                                onToggle: { Task { await toggle(row) } },
                                onRetranslate: { Task { await retranslate(row) } },
                                onDelete: { Task { await remove(row) } }
                            )
                        }
                    }
                }
            }
            .navigationTitle("中英对照")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await reload() }
            .onDisappear { work?.cancel() }
            .alert("翻译失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) { }
            } message: { Text(errorText ?? "") }
        }
    }

    private enum BatchScope { case page, chapter }

    @MainActor
    private func start(_ scope: BatchScope) {
        guard !busy else { return }
        let ranges = paragraphRanges().filter { range in
            guard scope == .page else { return true }
            let visibleStart = max(0, controller.visibleUTF16Offset)
            let rawEnd = max(visibleStart, controller.visibleUTF16End)
            let visibleEnd = rawEnd > visibleStart ? rawEnd : min((sourceText as NSString).length, visibleStart + 4_000)
            return NSIntersectionRange(range, NSRange(location: visibleStart, length: max(1, visibleEnd - visibleStart))).length > 0
        }
        guard !ranges.isEmpty else { status = "当前范围没有可翻译的英文段落"; return }
        busy = true; done = 0; total = ranges.count; status = "正在准备翻译…"
        let replace = replaceCached
        work = Task {
            do {
                let source = sourceText as NSString
                let cached = try await ParagraphTranslationRepository.shared.translations(bookId: bookId, chapterIndex: chapterIndex, source: sourceText)
                let cacheKeys = Set(cached.map { "\($0.start):\($0.end)" })
                var translated = 0, reused = 0
                for range in ranges {
                    try Task.checkCancellation()
                    let key = "\(range.location):\(NSMaxRange(range))"
                    if !replace && cacheKeys.contains(key) {
                        reused += 1
                    } else {
                        let paragraph = source.substring(with: range)
                        let result = try await TranslationService.shared.translate(paragraph)
                        try await ParagraphTranslationRepository.shared.save(
                            bookId: bookId, chapterIndex: chapterIndex,
                            start: range.location, end: NSMaxRange(range), source: sourceText,
                            translation: result, modelKey: "TRANSLATION"
                        )
                        translated += 1
                    }
                    await MainActor.run { done += 1; status = "已翻译 \(translated) 段 · 复用缓存 \(reused) 段" }
                }
                await reload()
                await MainActor.run {
                    settings.setBilingualVisible(true, bookId: bookId)
                    status = "完成：新翻译 \(translated) 段，复用 \(reused) 段"
                    busy = false; work = nil
                }
            } catch is CancellationError {
                await reload()
                await MainActor.run { status = "已停止，已完成的段落已保留"; busy = false; work = nil }
            } catch {
                await MainActor.run { errorText = error.localizedDescription; busy = false; work = nil }
            }
        }
    }

    @MainActor
    private func reload() async {
        do {
            rows = try await ParagraphTranslationRepository.shared.translations(bookId: bookId, chapterIndex: chapterIndex, source: sourceText)
            onChanged(rows)
        } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func toggle(_ row: ParagraphTranslationRecord) async {
        do {
            try await ParagraphTranslationRepository.shared.setHidden(bookId: bookId, chapterIndex: chapterIndex, start: row.start, end: row.end, source: sourceText, hidden: !row.isHidden)
            await reload()
        } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func retranslate(_ row: ParagraphTranslationRecord) async {
        guard !busy else { return }
        busy = true
        do {
            let ns = sourceText as NSString
            let range = NSRange(location: row.start, length: max(0, row.end - row.start))
            guard NSMaxRange(range) <= ns.length else { throw BilingualError.rangeChanged }
            let result = try await TranslationService.shared.translate(ns.substring(with: range))
            try await ParagraphTranslationRepository.shared.save(bookId: bookId, chapterIndex: chapterIndex, start: row.start, end: row.end, source: sourceText, translation: result, modelKey: "TRANSLATION")
            await reload()
        } catch { errorText = error.localizedDescription }
        busy = false
    }

    @MainActor
    private func remove(_ row: ParagraphTranslationRecord) async {
        do {
            try await ParagraphTranslationRepository.shared.remove(bookId: bookId, chapterIndex: chapterIndex, start: row.start, end: row.end, source: sourceText)
            await reload()
        } catch { errorText = error.localizedDescription }
    }

    private func sourceSnippet(_ row: ParagraphTranslationRecord) -> String {
        let ns = sourceText as NSString
        guard row.start >= 0, row.end > row.start, row.end <= ns.length else { return "原文范围已失效" }
        return ns.substring(with: NSRange(location: row.start, length: row.end - row.start))
    }

    private func paragraphRanges() -> [NSRange] {
        let ns = sourceText as NSString
        guard ns.length > 0 else { return [] }
        var output: [NSRange] = [], location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            var start = line.location
            var end = NSMaxRange(line)
            while end > start, CharacterSet.newlines.contains(UnicodeScalar(ns.character(at: end - 1))!) { end -= 1 }
            while start < end, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: start))!) { start += 1 }
            while end > start, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: end - 1))!) { end -= 1 }
            if end > start {
                let range = NSRange(location: start, length: end - start)
                let text = ns.substring(with: range)
                if Self.looksEnglish(text) { output.append(range) }
            }
            let next = NSMaxRange(line)
            if next <= location { break }
            location = next
        }
        return output
    }

    private static func looksEnglish(_ text: String) -> Bool {
        var latin = 0, letters = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letters += 1
                if scalar.value < 128 { latin += 1 }
            }
        }
        return latin >= 4 && latin * 10 >= max(1, letters) * 4
    }

    private enum BilingualError: LocalizedError {
        case rangeChanged
        var errorDescription: String? { "正文已经变化，请重新打开双语面板" }
    }
}

private struct TranslationCacheRow: View {
    let row: ParagraphTranslationRecord
    let source: String
    let busy: Bool
    var onToggle: () -> Void
    var onRetranslate: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(source).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
            Text(row.translatedText).textSelection(.enabled)
                .opacity(row.isHidden ? 0.55 : 1)
            HStack {
                Button(row.isHidden ? "显示本段" : "隐藏本段", action: onToggle)
                Button("重新翻译", action: onRetranslate)
                Spacer()
                Button("删除", role: .destructive, action: onDelete)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }
}

private extension ParagraphTranslationRecord {
    var stableID: String { "\(bookId):\(chapterIndex):\(start):\(end)" }
}
