import SwiftUI
import UIKit

@MainActor
final class ReadingReviewModel: ObservableObject {
    @Published var entries: [ReviewEntry] = []
    @Published var books: [Book] = []
    @Published var personas: [PersonaRecord] = []
    @Published var loading = true
    @Published var errorText: String?

    func load() async {
        loading = true
        do {
            let value = try await ReviewRepository.shared.snapshot()
            entries = value.entries; books = value.books; personas = value.personas
        } catch { errorText = error.localizedDescription }
        loading = false
    }

    func delete(_ entry: ReviewEntry) async {
        do { try await ReviewRepository.shared.delete(entry); await load() }
        catch { errorText = error.localizedDescription }
    }

    func save(_ entry: ReviewEntry, title: String, body: String) async throws {
        try await ReviewRepository.shared.update(entry, title: title, body: body)
        await load()
    }
}

struct ReadingReviewView: View {
    var initialBookId: Int64? = nil
    @EnvironmentObject private var libraryStore: LibraryStore
    @StateObject private var model = ReadingReviewModel()
    @State private var filter = ReviewFilter()
    @State private var selected: ReviewEntry?
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var composeBookId: Int64?
    @State private var showComposer = false
    @State private var showFullscreen = false
    @State private var fullscreenIndex = 0

    private var visible: [ReviewEntry] { ReadingReviewLogic.filter(model.entries, by: filter) }

    var body: some View {
        NavigationStack {
            Group {
                if model.loading { ProgressView("正在整理回顾…") }
                else if visible.isEmpty { ContentUnavailableView("没有符合条件的划线或笔记", systemImage: "quote.bubble") }
                else { content }
            }
            .navigationTitle("回顾")
            .searchable(text: Binding(get: { filter.query }, set: { filter.query = $0 }), prompt: "搜索书名、角色、划线和笔记")
            .toolbar { toolbar }
            .task {
                if filter.bookId == nil { filter.bookId = initialBookId }
                await model.load()
            }
            .refreshable { await model.load() }
            .sheet(item: $selected) { entry in
                ReviewDetailView(entry: entry) { title, body in
                    try await model.save(entry, title: title, body: body)
                } onDelete: {
                    await model.delete(entry)
                }
            }
            .sheet(isPresented: $showShare) { if let shareURL { ActivityView(items: [shareURL]) } }
            .sheet(isPresented: $showComposer) { if let bookId = composeBookId { ReviewComposerView(entries: ReadingReviewLogic.aiSources(visible, bookId: bookId), personas: model.personas) { await model.load() } } }
            .fullScreenCover(isPresented: $showFullscreen) {
                ReviewFullscreenPager(entries: visible, initialIndex: fullscreenIndex) { entry in
                    showFullscreen = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { selected = entry }
                }
            }
            .alert("回顾失败", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(model.errorText ?? "") }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(visible) { entry in
                    Button { selected = entry } label: { ReviewCard(entry: entry) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if entry.canLocate { Button("定位原文") { selected = entry } }
                            Button("删除", role: .destructive) { Task { await model.delete(entry) } }
                        }
                }
            }.padding()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !visible.isEmpty {
                Button {
                    fullscreenIndex = min(fullscreenIndex, max(0, visible.count - 1))
                    showFullscreen = true
                } label: { Image(systemName: "rectangle.on.rectangle.angled") }
                .accessibilityLabel("全屏翻阅")
            }
            Menu {
                Picker("来源", selection: $filter.source) { ForEach(ReviewSourceFilter.allCases) { Text($0.rawValue).tag($0) } }
                Picker("内容", selection: $filter.kind) { ForEach(ReviewKindFilter.allCases) { Text($0.rawValue).tag($0) } }
                Divider()
                Picker("书籍", selection: Binding<Int64?>(get: { filter.bookId }, set: { filter.bookId = $0 })) {
                    Text("全部书籍").tag(Int64?.none)
                    ForEach(model.books) { Text($0.title).tag(Optional($0.id)) }
                }
                if filter.source == .ai {
                    Picker("角色", selection: Binding<Int64?>(get: { filter.personaId }, set: { filter.personaId = $0 })) {
                        Text("全部角色").tag(Int64?.none)
                        ForEach(model.personas) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Toggle("最旧优先", isOn: $filter.oldestFirst)
            } label: { Image(systemName: "line.3.horizontal.decrease.circle") }

            Menu {
                Button("导出当前筛选为 Markdown") { export() }
                Divider()
                ForEach(Array(Set(visible.map { $0.book.id })).sorted(), id: \.self) { id in
                    if let book = model.books.first(where: { $0.id == id }) {
                        Button("与伴读共创 · \(book.title)") { composeBookId = id; showComposer = true }
                    }
                }
            } label: { Image(systemName: "square.and.arrow.up") }
        }
    }

    private func export() {
        Task {
            do {
                shareURL = try await ReviewRepository.shared.exportMarkdown(visible)
                showShare = true
            } catch { model.errorText = error.localizedDescription }
        }
    }
}

private struct ReviewFullscreenPager: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [ReviewEntry]
    let initialIndex: Int
    var onOpenDetail: (ReviewEntry) -> Void
    @State private var index: Int
    @State private var openReaderEntry: ReviewEntry?

    init(entries: [ReviewEntry], initialIndex: Int, onOpenDetail: @escaping (ReviewEntry) -> Void) {
        self.entries = entries
        self.initialIndex = min(max(0, initialIndex), max(0, entries.count - 1))
        self.onOpenDetail = onOpenDetail
        _index = State(initialValue: min(max(0, initialIndex), max(0, entries.count - 1)))
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("没有可翻阅内容", systemImage: "quote.bubble")
                } else {
                    TabView(selection: $index) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 22) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(entry.book.title).font(.largeTitle.bold())
                                        HStack(spacing: 8) {
                                            Text(entry.author)
                                            Text("·")
                                            Text(entry.kindLabel)
                                            Text("·")
                                            Text(entry.locationLabel)
                                        }
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    if !entry.title.isEmpty { Text(entry.title).font(.title2.bold()) }
                                    if !entry.quote.isEmpty {
                                        Text(entry.quote)
                                            .font(.title3)
                                            .italic()
                                            .textSelection(.enabled)
                                            .padding(18)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                                    }
                                    if !entry.body.isEmpty {
                                        Text(entry.body)
                                            .font(.body)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    if let annotation = entry.annotation { AnnotationMediaView(mediaJSON: annotation.mediaJSON) }
                                    HStack {
                                        if entry.canLocate {
                                            Button { openReaderEntry = entry } label: { Label("定位原文", systemImage: "scope") }
                                                .buttonStyle(.bordered)
                                        }
                                        Button { onOpenDetail(entry) } label: { Label("详情 / 编辑", systemImage: "square.and.pencil") }
                                            .buttonStyle(.borderedProminent)
                                    }
                                    Spacer(minLength: 40)
                                }
                                .frame(maxWidth: 760, alignment: .leading)
                                .padding(.horizontal, 26)
                                .padding(.vertical, 30)
                                .frame(maxWidth: .infinity)
                            }
                            .tag(offset)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .automatic))
                }
            }
            .navigationTitle(entries.isEmpty ? "全屏回顾" : "全屏回顾 · \(index + 1)/\(entries.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } } }
            .sheet(item: $openReaderEntry) { entry in
                NavigationStack { ReaderView(book: entry.book, startChapterIndex: entry.chapterIndex, startCharOffset: entry.charOffset) }
            }
        }
    }
}

private struct ReviewCard: View {
    let entry: ReviewEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.book.title).font(.headline).lineLimit(1)
                Spacer()
                Text(entry.kindLabel).font(.caption).foregroundStyle(.secondary)
            }
            if !entry.title.isEmpty { Text(entry.title).font(.title3.bold()) }
            if !entry.quote.isEmpty {
                Text(entry.quote).font(.body).italic().lineLimit(7)
                    .padding(.leading, 12).overlay(alignment: .leading) { Rectangle().frame(width: 3).foregroundStyle(.tint) }
            }
            if !entry.body.isEmpty { Text(entry.body).font(.body).lineLimit(8) }
            if let annotation = entry.annotation { AnnotationMediaView(mediaJSON: annotation.mediaJSON, compact: true) }
            HStack {
                Text(entry.author)
                Text("·")
                Text(entry.locationLabel)
                Spacer()
                Text(Date(timeIntervalSince1970: Double(entry.timestamp) / 1000), style: .date)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ReviewDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: ReviewEntry
    var onSave: (String, String) async throws -> Void
    var onDelete: () async -> Void
    @State private var title: String
    @State private var bodyText: String
    @State private var saving = false
    @State private var openReader = false
    @State private var errorText: String?
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var showDiscussion = false
    @ObservedObject private var templateStore = ReviewShareTemplateStore.shared

    init(entry: ReviewEntry, onSave: @escaping (String, String) async throws -> Void, onDelete: @escaping () async -> Void) {
        self.entry = entry; self.onSave = onSave; self.onDelete = onDelete
        _title = State(initialValue: entry.title); _bodyText = State(initialValue: entry.body)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(entry.book.title); LabeledContent("来源", value: entry.author); LabeledContent("位置", value: entry.locationLabel) }
                if !entry.quote.isEmpty { Section("原文") { Text(entry.quote).textSelection(.enabled) } }
                Section(entry.kind == .note ? "笔记" : "批注") {
                    if entry.kind == .note { TextField("标题", text: $title) }
                    TextEditor(text: $bodyText).frame(minHeight: 180)
                }
                if let annotation = entry.annotation, annotation.mediaJSON != "{}" {
                    Section("媒体") { AnnotationMediaView(mediaJSON: annotation.mediaJSON) }
                }
                if entry.canLocate { Section { Button("定位到原文") { openReader = true } } }
                if entry.annotation != nil {
                    Section("讨论") {
                        Button { showDiscussion = true } label: { Label("讨论这条批注", systemImage: "bubble.left.and.bubble.right") }
                    }
                }
                Section { Button("删除这条\(entry.kindLabel)", role: .destructive) { Task { await onDelete(); dismiss() } } }
            }
            .navigationTitle(entry.kindLabel)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Menu {
                        ForEach(templateStore.templates) { template in
                            Button("图片 · \(template.name)") { shareImage(template) }
                        }
                    } label: { Image(systemName: "square.and.arrow.up") }
                    Button(saving ? "保存中…" : "保存") { save() }.disabled(saving)
                }
            }
            .sheet(isPresented: $openReader) { NavigationStack { ReaderView(book: entry.book, startChapterIndex: entry.chapterIndex, startCharOffset: entry.charOffset) } }
            .sheet(isPresented: $showShare) { if let shareURL { ActivityView(items: [shareURL]) } }
            .sheet(isPresented: $showDiscussion) {
                if let annotation = entry.annotation { AnnotationDiscussionView(annotation: annotation, book: entry.book) }
            }
            .alert("保存失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorText ?? "") }
        }
    }

    private func save() {
        saving = true
        Task { do { try await onSave(title, bodyText); saving = false; dismiss() } catch { saving = false; errorText = error.localizedDescription } }
    }

    private func shareImage(_ template: ReviewShareTemplate) {
        do { shareURL = try ReviewCardExporter.writePNG(entry: entry, template: template); showShare = true }
        catch { errorText = error.localizedDescription }
    }
}

private struct ReviewComposerView: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [ReviewEntry]
    let personas: [PersonaRecord]
    var onSaved: () async -> Void
    @State private var personaId: Int64?
    @State private var instruction = ""
    @State private var draftTitle = ""
    @State private var draft = ""
    @State private var running = false
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("素材") {
                    Text("已选 \(entries.count) 条完整记录；一次最多 20 条、2.4 万字。")
                    ForEach(entries) { e in Text("\(e.locationLabel) · \(e.author) · \(e.quote.isEmpty ? e.title : e.quote)").lineLimit(2).font(.caption) }
                }
                Section("伴读角色") {
                    Picker("角色", selection: Binding<Int64?>(get: { personaId }, set: { personaId = $0 })) {
                        Text("请选择").tag(Int64?.none)
                        ForEach(personas) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section("共创要求") { TextEditor(text: $instruction).frame(minHeight: 80) }
                if running || !draft.isEmpty {
                    Section("草稿") {
                        TextField("标题", text: $draftTitle)
                        TextEditor(text: $draft).frame(minHeight: 220)
                        if running { ProgressView() }
                    }
                }
            }
            .navigationTitle("共创读书笔记")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { task?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if running { Button("停止") { task?.cancel(); running = false } }
                    else if draft.isEmpty { Button("生成") { generate() }.disabled(entries.isEmpty || personaId == nil) }
                    else { Button("保存笔记") { save() }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
            }
            .alert("共创失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorText ?? "") }
        }
    }

    private func generate() {
        guard let personaId, let persona = personas.first(where: { $0.id == personaId }), let book = entries.first?.book else { return }
        running = true; draft = ""; draftTitle = "关于《\(book.title)》的读书笔记"
        task = Task {
            do {
                let resolved = try await AIClientFactory.forRole(.chat)
                let personaPrompt = await PersonaRepository.shared.systemPrompt(for: persona)
                let system = personaPrompt + "\n\n请只依据用户提供的划线与笔记素材，整理一篇可编辑的读书笔记。不要补写未提供的剧情，不输出思考过程。"
                let prompt = "书名：《\(book.title)》\n共创要求：\(instruction.prefix(2000))\n\n以下是唯一可使用的素材：\n\(ReadingReviewLogic.aiSourceText(entries))"
                for try await delta in resolved.client.chatStream(messages: [.init(role: .system, content: system), .init(role: .user, content: prompt)], tools: [], options: resolved.options) {
                    if Task.isCancelled { throw CancellationError() }
                    if case .text(let chunk) = delta {
                        if (draft as NSString).length + (chunk as NSString).length > 32_000 { throw ReviewError.message("草稿超过 32000 字，请缩小素材范围") }
                        await MainActor.run { draft += chunk }
                    }
                }
            } catch is CancellationError {} catch { await MainActor.run { errorText = error.localizedDescription } }
            await MainActor.run { running = false }
        }
    }

    private func save() {
        guard let book = entries.first?.book, let personaId else { return }
        Task {
            do {
                let scope = ReadingScope.uptoProgress(book: book)
                let references = entries.enumerated().map { "[\($0.offset + 1)] \($0.element.locationLabel) · \($0.element.author)" }.joined(separator: "\n")
                _ = try await NoteRepository.shared.save(bookId: book.id, personaId: personaId, title: draftTitle.isEmpty ? "读书笔记" : draftTitle, content: draft.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n---\n\n素材出处\n\n" + references, kind: "NOTE", scope: scope)
                await onSaved(); dismiss()
            } catch { errorText = error.localizedDescription }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private enum ReviewError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
