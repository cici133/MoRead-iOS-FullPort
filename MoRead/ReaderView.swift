import SwiftUI
import UIKit

private struct ReaderProactiveNotice: Identifiable {
    let id = UUID()
    var message: String
    var chapterIndex: Int?
    var charOffset: Int?
}

struct ReaderView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var readerSettings = ReaderSettingsStore.shared
    @ObservedObject private var enhancementSettings = ReaderEnhancementSettingsStore.shared
    @ObservedObject private var companionSettings = CompanionAutonomySettingsStore.shared
    let book: Book

    @State private var chapters: [Chapter] = []
    @State private var chapterIndex: Int
    @State private var chapterText = ""
    @State private var epubRoot: URL?
    @State private var annotations: [ReaderAnnotation] = []
    @State private var translations: [ParagraphTranslationRecord] = []
    @State private var vocabularyGlosses: [VocabularyEntry] = []
    @AppStorage("reader.english.glosses") private var showEnglishGlosses = true
    @State private var textMapping: ReaderTextMapping?
    @State private var renderedText = ""
    @State private var renderCanonicalText = true
    @State private var selection: ReaderSelection?
    @State private var showContents = false
    @State private var showAI = false
    @State private var showReaderSettings = false
    @State private var showTools = false
    @State private var showSearch = false
    @State private var showBilingual = false
    @State private var showNoteEditor = false
    @State private var creationRequest: AICreationRequest?
    @State private var noteDraft = ""
    @State private var searchQuery = ""
    @State private var searchResults: [BookSearchHit] = []
    @State private var searchBusy = false
    @State private var searchError: String?
    @State private var loading = true
    @State private var errorText: String?
    @State private var enteredAt = Date()
    @State private var initialOffset: Int
    @State private var isAutoReading = false
    @State private var toolLookup = ""
    @State private var proactiveNotice: ReaderProactiveNotice?
    @State private var completedChapterSignals: Set<Int> = []
    @State private var previewImage: ReaderImagePreviewItem?
    @State private var pendingEpubFragment: String?
    @State private var externalLink: URL?
    @State private var companionPrefill = ""
    @State private var previousScreenBrightness: CGFloat?
    @State private var previousIdleTimerDisabled: Bool?

    @StateObject private var web = ReaderWebController()
    @StateObject private var listen = ContinuousListenSession()

    init(book: Book, startChapterIndex: Int? = nil, startCharOffset: Int? = nil) {
        self.book = book
        _chapterIndex = State(initialValue: max(0, startChapterIndex ?? book.lastReadChapterIndex))
        _initialOffset = State(initialValue: max(0, startCharOffset ?? book.lastReadCharOffset))
    }

    private var chapter: Chapter? { chapters.indices.contains(chapterIndex) ? chapters[chapterIndex] : nil }
    private var displayedAnnotations: [ReaderAnnotation] { companionSettings.showAIAnnotations ? annotations : annotations.filter { $0.personaId == nil } }
    private var preferences: ReaderPreferences { readerSettings.resolvedPreferences(bookId: book.id, isDark: colorScheme == .dark) }
    private var translationsVisible: Bool { preferences.showTranslations && readerSettings.bilingualVisible(bookId: book.id) }
    private var effectiveEnhancements: ReaderEnhancementSettings {
        var value = enhancementSettings.settings
        value.titleStyle = readerSettings.resolvedTitleStyle(bookId: book.id, isDark: colorScheme == .dark, fallback: value.titleStyle)
        return value
    }

    var body: some View {
        readerFinalView
    }

    private var readerBaseView: some View {
        readerLayout
            .navigationBarTitleDisplayMode(.inline)
            .statusBarHidden(preferences.hideStatusBar)
            .toolbar { readerToolbar }
            .sheet(isPresented: $showContents) { contentsSheet }
            .sheet(isPresented: Binding(get: { showAI && !usesCompanionSidebar }, set: { if !$0 { showAI = false } })) {
                if let chapter {
                    AICompanionView(book: book, chapter: chapter, chapterText: chapterText, visibleCharOffset: resolvedVisibleOffset(), initialDraft: companionPrefill)
                }
            }
            .sheet(isPresented: $showReaderSettings) { ReaderSettingsSheet(store: readerSettings, bookId: book.id) }
            .sheet(isPresented: $showTools) { ReaderToolsView(book: book, chapters: chapters, currentChapterIndex: chapterIndex, currentChapterText: chapterText, currentOffset: resolvedVisibleOffset(), initialLookup: toolLookup) }
            .sheet(isPresented: $showSearch) { searchSheet }
            .sheet(isPresented: $showBilingual) {
                BilingualReadingView(bookId: book.id, chapterIndex: chapterIndex, sourceText: chapterText, controller: web, settings: readerSettings) { rows in
                    translations = rows
                    web.setTranslations(rows, visible: readerSettings.bilingualVisible(bookId: book.id) && preferences.showTranslations)
                }
            }
            .sheet(isPresented: $showNoteEditor) { noteEditor }
            .sheet(item: $creationRequest) { request in
                if let chapter { AICreationView(book: book, chapter: chapter, chapterText: chapterText, request: request) }
            }
            .sheet(item: $previewImage) { ReaderImagePreviewView(item: $0) }
            .task {
                applyReaderDeviceSettings()
                await ProactiveAnnotationScheduler.shared.setReaderBook(book.id)
                await load()
                await ProactiveAnnotationScheduler.shared.onChapterEntered(bookId: book.id, chapterIndex: chapterIndex)
            }
            .background(ReaderHardwareKeyCapture { key in handleTap(preferences.keyBindings.action(for: key)) }.frame(width: 1, height: 1).opacity(0.01))
    }

    private var readerObservedView: some View {
        readerBaseView
            .onChange(of: web.visibleUTF16Offset) { _, _ in persistVisibleProgress() }
            .onChange(of: readerSettings.conversionMode(bookId: book.id)) { _, _ in rebuildPresentation() }
            .onChange(of: enhancementSettings.settings) { _, _ in rebuildPresentation() }
            .onChange(of: translationsVisible) { _, value in web.setTranslations(translations, visible: value) }
            .onChange(of: preferences.keepScreenOn) { _, _ in applyReaderDeviceSettings() }
            .onChange(of: preferences.screenBrightness) { _, _ in applyReaderDeviceSettings() }
            .onChange(of: companionSettings.showAIAnnotations) { _, _ in web.reloadAnnotations(displayedAnnotations) }
            .onChange(of: showEnglishGlosses) { _, value in web.setWordGlosses(vocabularyGlosses, visible: (preferences.englishLearningEnabled ?? false) && value) }
            .onChange(of: preferences.englishLearningEnabled) { _, value in web.setWordGlosses(vocabularyGlosses, visible: (value ?? false) && showEnglishGlosses) }
            .onChange(of: preferences.englishBionicEnabled) { _, value in web.setBionicReading(value ?? false) }
            .onChange(of: listen.tts.highlightedRange) { _, range in web.setSpeechHighlight(range) }
            .onReceive(NotificationCenter.default.publisher(for: .proactiveAnnotationPolicyChanged)) { _ in
                Task { await ProactiveAnnotationScheduler.shared.policyChanged(bookId: book.id, chapterIndex: chapterIndex) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .proactiveAnnotationsDidChange)) { note in
                guard let bid = note.userInfo?["bookId"] as? Int64, bid == book.id else { return }
                let changedChapter = note.userInfo?["chapterIndex"] as? Int ?? -1
                let ids = note.userInfo?["createdIds"] as? [Int64] ?? []
                let message = note.userInfo?["message"] as? String
                Task { @MainActor in
                    var target: ReaderAnnotation?
                    if changedChapter >= 0, changedChapter <= chapterIndex {
                        if let rows = try? await ReaderRecordRepository.shared.annotations(bookId: book.id, chapterIndex: changedChapter) {
                            target = rows.first { ids.contains($0.id) }
                            if changedChapter == chapterIndex {
                                annotations = rows
                                web.reloadAnnotations(companionSettings.showAIAnnotations ? rows : rows.filter { $0.personaId == nil })
                            }
                        }
                    }
                    if let message {
                        proactiveNotice = .init(message: message, chapterIndex: target?.chapterIndex, charOffset: target?.startCharOffset)
                        let noticeID = proactiveNotice?.id
                        Task {
                            try? await Task.sleep(for: .seconds(5))
                            await MainActor.run { if proactiveNotice?.id == noticeID { proactiveNotice = nil } }
                        }
                    }
                }
            }
    }

    private var readerOverlayView: some View {
        readerObservedView
            .overlay(alignment: .top) {
                if let notice = proactiveNotice {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                        Text(notice.message).font(.footnote.weight(.medium)).lineLimit(2)
                        if let targetChapter = notice.chapterIndex, let targetOffset = notice.charOffset {
                            Button("查看") {
                                proactiveNotice = nil
                                Task { @MainActor in
                                    if targetChapter == chapterIndex {
                                        let a = BookTextSearch.anchor(around: targetOffset, in: chapterText)
                                        web.scrollTo(offset: targetOffset, anchor: a.text, anchorRelativeOffset: a.relative)
                                    } else {
                                        await jump(to: targetChapter, offset: targetOffset)
                                    }
                                }
                            }.buttonStyle(.borderless)
                        }
                        Button { proactiveNotice = nil } label: { Image(systemName: "xmark").font(.caption) }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
    }

    private var readerFinalView: some View {
        readerOverlayView
            .onDisappear {
                stopAndRecord()
                restoreReaderDeviceSettings()
                Task { await ProactiveAnnotationScheduler.shared.clearReaderBook(book.id) }
            }
            .alert("阅读失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(errorText ?? "") }
            .confirmationDialog("打开外部链接？", isPresented: Binding(get: { externalLink != nil }, set: { if !$0 { externalLink = nil } }), titleVisibility: .visible) {
                if let url = externalLink {
                    Button("在系统浏览器打开") { externalLink = nil; UIApplication.shared.open(url) }
                }
                Button("取消", role: .cancel) { externalLink = nil }
            } message: { Text(externalLink?.absoluteString ?? "") }
    }

    private var usesCompanionSidebar: Bool { horizontalSizeClass == .regular }

    @ViewBuilder private var readerLayout: some View {
        if usesCompanionSidebar, showAI, let chapter {
            HStack(spacing: 0) {
                readerCanvas
                Divider()
                AICompanionView(book: book, embedded: true, chapter: chapter, chapterText: chapterText, visibleCharOffset: resolvedVisibleOffset(), initialDraft: companionPrefill)
                    .frame(minWidth: 360, idealWidth: 420, maxWidth: 520)
                    .background(.background)
            }
        } else {
            readerCanvas
        }
    }

    @ViewBuilder private var readerCanvas: some View {
        Group {
            if loading { ProgressView("正在排版…") }
            else if let chapter {
                ReaderWebView(
                    document: document(for: chapter),
                    controller: web,
                    onTapAction: handleTap,
                    onSelection: { selection = $0 },
                    onImageLongPress: { url in if let safe = validatedReaderImageURL(url) { previewImage = .init(url: safe, book: book) } },
                    onLink: { url in Task { await handleReaderLink(url) } },
                    onBoundary: { direction in Task { await move(direction) } },
                    onQuickBookmark: { Task { await addBookmarkIfMissing() } },
                    onReady: {
                        web.reloadAnnotations(displayedAnnotations)
                        web.setTranslations(translations, visible: translationsVisible)
                        web.setWordGlosses(vocabularyGlosses, visible: (preferences.englishLearningEnabled ?? false) && showEnglishGlosses)
                        web.setBionicReading(preferences.englishBionicEnabled ?? false)
                        if let fragment = pendingEpubFragment {
                            pendingEpubFragment = nil
                            web.scrollToFragment(fragment)
                        }
                        if isAutoReading { web.setAutoRead(active: true, settings: preferences.autoRead) }
                    }
                )
                .id("\(chapter.id)-\(preferences.hashForReaderReload)-\(readerSettings.conversionMode(bookId: book.id).rawValue)-\(effectiveEnhancements.hashValue)")
                .ignoresSafeArea(edges: preferences.hideStatusBar ? .top : [])
                .navigationTitle(chapter.title)
                .overlay(alignment: .bottom) { selectionBar }
            } else { ContentUnavailableView("章节不可用", systemImage: "exclamationmark.triangle") }
        }
    }

    private func document(for chapter: Chapter) -> ReaderWebDocument {
        var fileURL: URL?
        if !renderCanonicalText, book.sourceType.uppercased() == "EPUB", let root = epubRoot, !chapter.href.isEmpty {
            let path = chapter.href.components(separatedBy: "#").first?.removingPercentEncoding ?? chapter.href
            let candidate = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) { fileURL = candidate }
        }
        let initialAnchor = renderCanonicalText ? (text: "", relative: 0) : BookTextSearch.anchor(around: initialOffset, in: chapterText)
        return .init(
            fileURL: fileURL,
            readAccessURL: epubRoot,
            plainText: renderCanonicalText ? renderedText : chapterText,
            chapterIndex: chapter.chapterIndex,
            chapterTitle: chapter.title,
            enhancements: effectiveEnhancements,
            initialUTF16Offset: initialOffset,
            annotations: displayedAnnotations,
            preferences: preferences,
            textMapping: renderCanonicalText ? textMapping : nil,
            initialAnchorText: initialAnchor.text,
            initialAnchorRelativeOffset: initialAnchor.relative
        )
    }

    @ToolbarContentBuilder private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button { showContents = true } label: { Image(systemName: "list.bullet") }
            Spacer()
            Button { web.previousPage() } label: { Image(systemName: "chevron.left") }
            Button { toggleListen() } label: { Image(systemName: listen.isActive ? "stop.fill" : "speaker.wave.2.fill") }
            Button { showAI = true } label: { Image(systemName: "sparkles") }.disabled(chapter == nil)
            Button { web.nextPage() } label: { Image(systemName: "chevron.right") }
            Spacer()
            Menu {
                Button("书内搜索") { showSearch = true }
                Button("大纲 / 人物 / 词典 / 插图 / 有声书") { toolLookup = ""; showTools = true }
                Button("添加 / 移除书签") { Task { await toggleBookmark() } }
                Button("中英对照") { showBilingual = true }
                Button(translationsVisible ? "隐藏本书译文" : "显示本书译文") { readerSettings.setBilingualVisible(!readerSettings.bilingualVisible(bookId: book.id), bookId: book.id) }
                Menu("自动阅读") {
                    if isAutoReading { Button("暂停自动阅读") { stopAutoRead() } }
                    else { Button("开始自动阅读") { startAutoRead() } }
                    Picker("方式", selection: $readerSettings.preferences.autoRead.mode) { Text("匀速滚动").tag(PageMode.scroll); Text("定时翻页").tag(PageMode.page) }
                }
                Button("阅读设置") { showReaderSettings = true }
                Menu("睡眠定时") {
                    Button("本章结束") { listen.setSleepTimer(.endOfChapter) }
                    Button("15 分钟") { listen.setSleepTimer(.minutes(15)) }
                    Button("30 分钟") { listen.setSleepTimer(.minutes(30)) }
                    Button("1 章") { listen.setSleepTimer(.chapters(1)) }
                    Button("3 章") { listen.setSleepTimer(.chapters(3)) }
                    Button("关闭") { listen.setSleepTimer(nil) }
                }
            } label: { Image(systemName: "textformat.size") }
        }
    }

    @ViewBuilder private var selectionBar: some View {
        if selection != nil {
            HStack(spacing: 18) {
                Button("高亮") { Task { await saveSelection(note: "") } }
                Button("批注") { noteDraft = ""; showNoteEditor = true }
                Button("查词") { if let selection { Task { await openDictionary(selection.text) } } }
                Button("生词") { Task { await saveVocabularyFromSelection() } }
                Button("翻译") { Task { await translateSelectionParagraph() } }
                Button("改写") { if let selection { creationRequest = .init(type: .rewrite, start: selection.canonicalStart ?? selection.approximateUTF16Offset, end: selection.canonicalEnd ?? (selection.approximateUTF16Offset + (selection.text as NSString).length), selectedText: selection.text) } }
                Button("续写") { if let selection { let end = selection.canonicalEnd ?? (selection.approximateUTF16Offset + (selection.text as NSString).length); creationRequest = .init(type: .continueWriting, start: end, end: end, selectedText: selection.text) } }
                Menu("伴读") {
                    Button("解析选中原文") { prefillCompanionForSelection(.explain) }
                    Button("围绕这段提问") { prefillCompanionForSelection(.ask) }
                    Button("角色共读点评") { prefillCompanionForSelection(.discuss) }
                }
                Button("取消") { selection = nil }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 12)
        }
    }

    private var contentsSheet: some View {
        NavigationStack {
            List(chapters) { item in
                Button { Task { await jump(to: item.chapterIndex); showContents = false } } label: {
                    HStack { Text(item.title); Spacer(); if item.chapterIndex == chapterIndex { Image(systemName: "checkmark") } }
                }
            }.navigationTitle("目录 / 人物")
        }
    }

    private var searchSheet: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("搜索全书", text: $searchQuery).textInputAutocapitalization(.never)
                            .onSubmit { Task { await performBookSearch() } }
                        if searchBusy { ProgressView().controlSize(.small) }
                        Button("查找") { Task { await performBookSearch() } }.disabled(searchBusy || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let searchError { Text(searchError).font(.caption).foregroundStyle(.red) }
                    if !searchQuery.isEmpty && !searchBusy {
                        Text("找到 \(searchResults.count) 处；结果坐标来自 text.mz UTF-16 原文。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("结果") {
                    ForEach(searchResults) { result in
                        Button {
                            showSearch = false
                            Task { @MainActor in await openSearchResult(result) }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("第 \(result.chapterIndex + 1) 章 · \(result.chapterTitle)").font(.subheadline.weight(.semibold))
                                Text(result.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                }
            }
            .navigationTitle("书内搜索")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showSearch = false } } }
        }
    }

    @MainActor private func performBookSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchResults = []; searchError = nil; return }
        searchBusy = true; searchError = nil
        do { searchResults = try await BookTextSearch.search(bookId: book.id, chapters: chapters, query: query) }
        catch is CancellationError { }
        catch { searchError = error.localizedDescription }
        searchBusy = false
    }

    @MainActor private func openSearchResult(_ result: BookSearchHit) async {
        if result.chapterIndex == chapterIndex {
            web.scrollTo(offset: result.startUTF16, anchor: result.anchorText, anchorRelativeOffset: result.anchorRelativeOffset)
        } else {
            await jump(to: result.chapterIndex, offset: result.startUTF16)
        }
    }

    private var noteEditor: some View {
        NavigationStack {
            Form {
                if let selection { Text(selection.text).font(.callout).foregroundStyle(.secondary) }
                TextEditor(text: $noteDraft).frame(minHeight: 120)
            }
            .navigationTitle("批注")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showNoteEditor = false } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await saveSelection(note: noteDraft); showNoteEditor = false } } }
            }
        }
    }

    @MainActor private func handleReaderLink(_ url: URL) async {
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            externalLink = url
            return
        }
        guard url.isFileURL, let root = epubRoot else {
            errorText = "不支持的链接：\(url.absoluteString)"
            return
        }
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let targetPath = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
        guard targetPath == root.standardizedFileURL.path || targetPath.hasPrefix(rootPath) else {
            errorText = "已阻止跳出 EPUB 的本地链接"
            return
        }
        var relative = targetPath == root.standardizedFileURL.path ? "" : String(targetPath.dropFirst(rootPath.count))
        relative = relative.removingPercentEncoding ?? relative
        let normalizedTarget = normalizeEpubPath(relative)
        guard let target = chapters.first(where: { normalizeEpubPath($0.href) == normalizedTarget }) else {
            errorText = "无法定位这个 EPUB 内链"
            return
        }
        let fragment = url.fragment?.removingPercentEncoding ?? url.fragment
        if target.chapterIndex == chapterIndex {
            if let fragment, !fragment.isEmpty { web.scrollToFragment(fragment) }
            return
        }
        pendingEpubFragment = fragment?.isEmpty == false ? fragment : nil
        await jump(to: target.chapterIndex, offset: 0)
    }

    private func normalizeEpubPath(_ value: String) -> String {
        let raw = (value.removingPercentEncoding ?? value).components(separatedBy: "#").first ?? value
        let cleaned = raw.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(fileURLWithPath: "/" + cleaned).standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    @MainActor private func load() async {
        do {
            chapters = try await store.chapters(bookId: book.id)
            guard !chapters.isEmpty else { throw LibraryRepository.ImportError.noChapters }
            chapterIndex = min(max(0, chapterIndex), chapters.count - 1)
            if book.sourceType.uppercased() == "EPUB" { epubRoot = try await EPUBResourceStore.shared.extractedRoot(bookId: book.id) }
            try await loadChapter()
            configureListenCallbacks()
        } catch { errorText = error.localizedDescription }
        loading = false
    }

    @MainActor private func move(_ delta: Int) async {
        if delta > 0 { await markChapterCompletedIfNeeded(chapterIndex, force: true) }
        await jump(to: chapterIndex + delta)
    }

    @MainActor private func jump(to index: Int, offset: Int = 0) async {
        guard chapters.indices.contains(index) else { return }
        persistVisibleProgress()
        chapterIndex = index; initialOffset = max(0, offset); selection = nil
        do {
            try await loadChapter()
            try await store.updateProgress(bookId: book.id, chapterIndex: index, charOffset: initialOffset, reachedEnd: index == chapters.count - 1 && initialOffset >= max(0, chapters[index].charCount - 1))
            await ProactiveAnnotationScheduler.shared.onChapterEntered(bookId: book.id, chapterIndex: index)
        } catch { errorText = error.localizedDescription }
    }

    @MainActor private func loadChapter() async throws {
        guard chapters.indices.contains(chapterIndex) else { return }
        chapterText = try await store.chapterText(chapters[chapterIndex])
        annotations = try await ReaderRecordRepository.shared.annotations(bookId: book.id, chapterIndex: chapterIndex)
        translations = try await ParagraphTranslationRepository.shared.translations(bookId: book.id, chapterIndex: chapterIndex, source: chapterText)
        vocabularyGlosses = try await VocabularyRepository.shared.list().filter { $0.bookId == book.id && $0.chapterIndex == chapterIndex && $0.charOffset != nil }
        rebuildPresentation()
    }

    private func handleTap(_ action: ReaderTapAction) {
        switch action {
        case .none: break
        case .previousPage: web.previousPage()
        case .nextPage: web.nextPage()
        case .menu, .settings: showReaderSettings = true
        case .contents: showContents = true
        case .bookmarks: showContents = true
        case .toggleBookmark: Task { await toggleBookmark() }
        case .previousChapter: Task { await move(-1) }
        case .nextChapter: Task { await move(1) }
        case .search: showSearch = true
        case .toggleTranslations: readerSettings.setBilingualVisible(!readerSettings.bilingualVisible(bookId: book.id), bookId: book.id)
        case .englishLearning: toolLookup = selection?.text ?? ""; showTools = true
        }
    }

    private enum SelectionCompanionAction { case explain, ask, discuss }

    @MainActor private func prefillCompanionForSelection(_ action: SelectionCompanionAction) {
        guard let selection, let range = ReaderAnchorResolver.resolveSelection(selection, in: chapterText), range.length > 0 else { return }
        let quote = (chapterText as NSString).substring(with: range)
        let task: String = switch action {
        case .explain: "请解析这段原文的含义、语气、细节和可能的上下文作用；把事实与推断分开。"
        case .ask: "我想围绕这段原文继续提问。先简要确认你理解的内容，再等我补充问题；如果需要上下文，请只检索已读范围。"
        case .discuss: "请以当前伴读角色的视角和我共读点评这段原文，可以谈感受、线索或写法，但不要剧透未读内容。"
        }
        companionPrefill = """
        \(task)

        〔选中原文 第\(chapterIndex + 1)章 · UTF-16 \(range.location)-\(range.location + range.length)〕
        「\(quote)」
        """
        showAI = true
    }

    @MainActor private func openDictionary(_ word: String) async {
        toolLookup = word.trimmingCharacters(in: .whitespacesAndNewlines)
        showTools = true
    }

    @MainActor private func rebuildPresentation() {
        let mode = readerSettings.conversionMode(bookId: book.id)
        let rules = enhancementSettings.settings.replacementRules
        let hasDisplayReplacement = rules.contains { $0.enabled && !$0.forListenOnly && !$0.pattern.isEmpty }
        // EPUB without text transforms keeps publisher XHTML/CSS. Any display transform switches to
        // canonical text.mz so persistent coordinates always remain source UTF-16 offsets.
        renderCanonicalText = book.sourceType.uppercased() != "EPUB" || mode != .off || hasDisplayReplacement
        if renderCanonicalText {
            let replaced = ReaderTextReplacementEngine.displayText(chapterText, rules: rules)
            let converted = ChineseTextConverter.shared.mapping(for: replaced, mode: mode).display
            let mapping = ReaderTextMapping(source: chapterText, display: converted)
            textMapping = mapping
            renderedText = mapping.display
        } else {
            textMapping = nil
            renderedText = chapterText
        }
    }

    @MainActor private func startAutoRead() {
        isAutoReading = true
        web.setAutoRead(active: true, settings: preferences.autoRead)
    }

    @MainActor private func stopAutoRead() {
        isAutoReading = false
        web.setAutoRead(active: false, settings: preferences.autoRead)
    }

    @MainActor private func translateSelectionParagraph() async {
        guard let selection, let selected = ReaderAnchorResolver.resolveSelection(selection, in: chapterText) else { return }
        let paragraph = paragraphRange(containing: selected.location, in: chapterText)
        guard paragraph.length > 0 else { return }
        do {
            let source = (chapterText as NSString).substring(with: paragraph)
            let translated = try await TranslationService.shared.translate(source)
            try await ParagraphTranslationRepository.shared.save(
                bookId: book.id, chapterIndex: chapterIndex, start: paragraph.location,
                end: paragraph.location + paragraph.length, source: chapterText, translation: translated, modelKey: "TRANSLATION"
            )
            translations = try await ParagraphTranslationRepository.shared.translations(bookId: book.id, chapterIndex: chapterIndex, source: chapterText)
            readerSettings.setBilingualVisible(true, bookId: book.id)
            web.setTranslations(translations, visible: preferences.showTranslations)
        } catch { errorText = error.localizedDescription }
    }

    @MainActor private func saveVocabularyFromSelection() async {
        guard let selection, let range = ReaderAnchorResolver.resolveSelection(selection, in: chapterText), range.length > 0 else { return }
        let word = (chapterText as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        do {
            let definitions = try await LocalDictionaryRepository.shared.lookup(word)
            let paragraph = paragraphRange(containing: range.location, in: chapterText)
            let context = paragraph.length > 0 ? (chapterText as NSString).substring(with: paragraph) : selection.text
            let enriched = await EnglishLearningService.shared.enrich(word: word, context: context, localDefinitions: definitions)
            let now = VocabularyRepository.now()
            try await VocabularyRepository.shared.save(.init(word: word, phonetic: enriched.phonetic, shortGloss: enriched.gloss, definitionMarkdown: enriched.markdown.isEmpty ? (definitions.first?.html ?? "") : enriched.markdown, sourceDictionaryId: definitions.first?.dictionaryId, bookId: book.id, chapterIndex: chapterIndex, charOffset: range.location, learned: false, createdAt: now, updatedAt: now))
            vocabularyGlosses = try await VocabularyRepository.shared.list().filter { $0.bookId == book.id && $0.chapterIndex == chapterIndex && $0.charOffset != nil }
            web.setWordGlosses(vocabularyGlosses, visible: (preferences.englishLearningEnabled ?? false) && showEnglishGlosses)
        } catch { errorText = error.localizedDescription }
    }

    private func paragraphRange(containing utf16Offset: Int, in text: String) -> NSRange {
        let ns = text as NSString, length = ns.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let offset = min(max(0, utf16Offset), max(0, length - 1))
        let before = ns.substring(with: NSRange(location: 0, length: offset)) as NSString
        let left = before.range(of: "\n", options: .backwards).location
        let start = left == NSNotFound ? 0 : left + 1
        let remaining = NSRange(location: start, length: length - start)
        let newline = ns.range(of: "\n", options: [], range: remaining).location
        let end = newline == NSNotFound ? length : newline
        var a = start, b = end
        while a < b && CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: a))!) { a += 1 }
        while b > a && CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: b - 1))!) { b -= 1 }
        return NSRange(location: a, length: max(0, b - a))
    }

    @MainActor private func saveSelection(note: String) async {
        guard let selection, let range = ReaderAnchorResolver.resolveSelection(selection, in: chapterText), range.length > 0 else { return }
        do {
            _ = try await ReaderRecordRepository.shared.addAnnotation(bookId: book.id, chapterIndex: chapterIndex, start: range.location, end: range.location + range.length, text: (chapterText as NSString).substring(with: range), note: note)
            annotations = try await ReaderRecordRepository.shared.annotations(bookId: book.id, chapterIndex: chapterIndex)
            web.reloadAnnotations(displayedAnnotations); self.selection = nil
        } catch { errorText = error.localizedDescription }
    }

    @MainActor private func toggleBookmark() async {
        let offset = resolvedVisibleOffset()
        do {
            if let existing = try await ReaderRecordRepository.shared.bookmark(bookId: book.id, chapterIndex: chapterIndex, charOffset: offset) { try await ReaderRecordRepository.shared.deleteBookmark(id: existing.id) }
            else { _ = try await ReaderRecordRepository.shared.addBookmark(bookId: book.id, chapterIndex: chapterIndex, charOffset: offset, excerpt: ReaderAnchorResolver.excerpt(around: offset, in: chapterText)) }
        } catch { errorText = error.localizedDescription }
    }

    @MainActor private func addBookmarkIfMissing() async {
        let offset = resolvedVisibleOffset()
        do {
            if try await ReaderRecordRepository.shared.bookmark(bookId: book.id, chapterIndex: chapterIndex, charOffset: offset) == nil {
                _ = try await ReaderRecordRepository.shared.addBookmark(bookId: book.id, chapterIndex: chapterIndex, charOffset: offset, excerpt: ReaderAnchorResolver.excerpt(around: offset, in: chapterText))
            }
        } catch { errorText = error.localizedDescription }
    }

    private func resolvedVisibleOffset() -> Int {
        ReaderAnchorResolver.resolve(needle: web.visibleAnchorText, approximateOffset: web.visibleUTF16Offset, in: chapterText) ?? min(max(0, web.visibleUTF16Offset), chapterText.utf16.count)
    }

    private func persistVisibleProgress() {
        guard !loading, chapters.indices.contains(chapterIndex) else { return }
        let offset = resolvedVisibleOffset(); initialOffset = offset
        let chapterReachedEnd = offset >= max(0, chapters[chapterIndex].charCount - 2)
        let bookReachedEnd = chapterIndex == chapters.count - 1 && chapterReachedEnd
        Task {
            try? await store.updateProgress(bookId: book.id, chapterIndex: chapterIndex, charOffset: offset, reachedEnd: bookReachedEnd)
            if chapterReachedEnd { await markChapterCompletedIfNeeded(chapterIndex) }
        }
    }

    @MainActor private func markChapterCompletedIfNeeded(_ index: Int, force: Bool = false) async {
        guard chapters.indices.contains(index) else { return }
        if !force {
            let offset = index == chapterIndex ? resolvedVisibleOffset() : chapters[index].charCount
            guard offset >= max(0, chapters[index].charCount - 2) else { return }
        }
        guard completedChapterSignals.insert(index).inserted else { return }
        await ProactiveAnnotationScheduler.shared.onChapterCompleted(bookId: book.id, chapterIndex: index)
    }

    @MainActor private func toggleListen() {
        if listen.isActive { listen.stop(); web.setSpeechHighlight(nil) }
        else { Task { await listen.start(book: book, chapters: chapters, chapterIndex: chapterIndex, charOffset: resolvedVisibleOffset()) } }
    }

    @MainActor private func configureListenCallbacks() {
        listen.onChapterChanged = { index, offset in Task { @MainActor in
            if self.chapterIndex != index {
                let previous = self.chapterIndex
                if index > previous { await self.markChapterCompletedIfNeeded(previous, force: true) }
                await self.jump(to: index, offset: offset)
            } else { self.web.scrollTo(offset: offset) }
        } }
        listen.onPositionChanged = { index, offset in Task { @MainActor in if self.chapterIndex == index { self.web.scrollTo(offset: offset) }; try? await self.store.updateProgress(bookId: self.book.id, chapterIndex: index, charOffset: offset, reachedEnd: false) } }
    }

    @MainActor private func applyReaderDeviceSettings() {
        if previousIdleTimerDisabled == nil { previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled }
        UIApplication.shared.isIdleTimerDisabled = preferences.keepScreenOn ?? false

        if previousScreenBrightness == nil { previousScreenBrightness = UIScreen.main.brightness }
        if let value = preferences.screenBrightness {
            UIScreen.main.brightness = CGFloat(min(1, max(0, value)))
        } else if let previousScreenBrightness {
            UIScreen.main.brightness = previousScreenBrightness
        }
    }

    @MainActor private func restoreReaderDeviceSettings() {
        if let previousIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled }
        if let previousScreenBrightness { UIScreen.main.brightness = previousScreenBrightness }
        self.previousIdleTimerDisabled = nil
        self.previousScreenBrightness = nil
    }

    private func validatedReaderImageURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        let candidate = url.standardizedFileURL
        let roots = [epubRoot, try? MoReadDatabase.applicationDirectory()].compactMap { $0?.standardizedFileURL }
        guard roots.contains(where: { candidate.path == $0.path || candidate.path.hasPrefix($0.path + "/") }) else { return nil }
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func stopAndRecord() {
        persistVisibleProgress(); listen.stop(); stopAutoRead()
        let ms = Int64(max(0, Date().timeIntervalSince(enteredAt) * 1000))
        Task { try? await LibraryRepository.shared.recordReading(bookId: book.id, durationMs: ms) }
    }
}

private extension ReaderPreferences {
    var hashForReaderReload: Int {
        var h = Hasher(); h.combine(layoutMode.rawValue); h.combine(writingMode.rawValue); h.combine(pageAnimation.rawValue); h.combine(twoPageSpread); h.combine(fontSize); h.combine(lineHeight); h.combine(paragraphSpacing); h.combine(paragraphIndentEM); h.combine(horizontalMargin); h.combine(verticalMargin); h.combine(fontFamily); h.combine(publisherStyleMode.rawValue); h.combine(theme.backgroundHex); h.combine(theme.foregroundHex); h.combine(customCSS); return h.finalize()
    }
}

private struct ReaderSettingsSheet: View {
    @ObservedObject var store: ReaderSettingsStore
    @AppStorage("reader.english.glosses") private var showEnglishGlosses = true
    @ObservedObject private var proactive = ProactiveAnnotationSettingsStore.shared
    let bookId: Int64
    var body: some View {
        NavigationStack {
            Form {
                Picker("阅读模式", selection: $store.preferences.layoutMode) { Text("滚动").tag(ReaderLayoutMode.scroll); Text("分页").tag(ReaderLayoutMode.paged) }
                Picker("书写方向", selection: $store.preferences.writingMode) { Text("横排").tag(ReaderWritingMode.horizontal); Text("竖排").tag(ReaderWritingMode.vertical) }
                Toggle("双页", isOn: $store.preferences.twoPageSpread)
                Picker("翻页效果", selection: $store.preferences.pageAnimation) { ForEach(ReaderPageAnimation.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("EPUB 出版方样式", selection: $store.preferences.publisherStyleMode) { ForEach(ReaderPublisherStyleMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                LabeledContent("字号") { Slider(value: $store.preferences.fontSize, in: 12...40, step: 1).frame(width: 180) }
                LabeledContent("行距") { Slider(value: $store.preferences.lineHeight, in: 1.1...2.6, step: 0.05).frame(width: 180) }
                Picker("繁简转换", selection: Binding(get: { store.conversionMode(bookId: bookId) }, set: { store.setConversion($0, bookId: bookId) })) { Text("关闭").tag(ChineseConversionMode.off); Text("繁→简").tag(ChineseConversionMode.tw2sp); Text("简→繁台").tag(ChineseConversionMode.s2twp) }
                Toggle("本书显示中英对照", isOn: Binding(
                    get: { store.bilingualVisible(bookId: bookId) },
                    set: { store.setBilingualVisible($0, bookId: bookId) }
                ))
                Toggle("英文生词标注", isOn: Binding(
                    get: { store.preferences.englishLearningEnabled ?? false },
                    set: { store.preferences.englishLearningEnabled = $0 }
                ))
                Toggle("英文仿生阅读", isOn: Binding(
                    get: { store.preferences.englishBionicEnabled ?? false },
                    set: { store.preferences.englishBionicEnabled = $0 }
                ))
                Toggle("显示英语音标 / 词下短释义", isOn: $showEnglishGlosses)
                    .disabled(!(store.preferences.englishLearningEnabled ?? false))
                Toggle("隐藏状态栏", isOn: $store.preferences.hideStatusBar)
                Toggle("阅读时保持亮屏", isOn: Binding(
                    get: { store.preferences.keepScreenOn ?? false },
                    set: { store.preferences.keepScreenOn = $0 }
                ))
                Toggle("自定义阅读亮度", isOn: Binding(
                    get: { store.preferences.screenBrightness != nil },
                    set: { enabled in store.preferences.screenBrightness = enabled ? Double(UIScreen.main.brightness) : nil }
                ))
                if store.preferences.screenBrightness != nil {
                    LabeledContent("亮度 \(Int((store.preferences.screenBrightness ?? 0.5) * 100))%") {
                        Slider(value: Binding(
                            get: { store.preferences.screenBrightness ?? 0.5 },
                            set: { store.preferences.screenBrightness = min(1, max(0, $0)) }
                        ), in: 0...1, step: 0.01).frame(width: 180)
                    }
                }
                Section("自动阅读") {
                    Picker("方式", selection: $store.preferences.autoRead.mode) { Text("匀速滚动").tag(PageMode.scroll); Text("定时翻页").tag(PageMode.page) }
                    if store.preferences.autoRead.mode == .scroll {
                        LabeledContent("速度 \(Int(store.preferences.autoRead.scrollDpPerSecond)) pt/s") { Slider(value: $store.preferences.autoRead.scrollDpPerSecond, in: 8...96, step: 2).frame(width: 160) }
                    } else {
                        Stepper("每 \(store.preferences.autoRead.pageIntervalSeconds) 秒翻页", value: $store.preferences.autoRead.pageIntervalSeconds, in: 3...120)
                    }
                }
                Section("外接键盘") {
                    ForEach(ReaderHardwareKey.allCases, id: \.self) { key in
                        Picker(key.label, selection: Binding(get: { store.preferences.keyBindings.actions[key] ?? .none }, set: { store.preferences.keyBindings.actions[key] = $0 })) {
                            ForEach(ReaderTapAction.allCases, id: \.self) { action in Text(action.rawValue).tag(action) }
                        }
                    }
                }
                Section("阅读主题 · 本书") {
                    let current = store.preferences.resolvedBookThemeOverrides[bookId] ?? BookReaderThemeOverride()
                    Toggle("本书使用独立日夜主题", isOn: Binding(
                        get: { current.enabled },
                        set: { enabled in var all = store.preferences.resolvedBookThemeOverrides; var value = all[bookId] ?? .init(); value.enabled = enabled; all[bookId] = value; store.preferences.bookThemeOverrides = all }
                    ))
                    if current.enabled {
                        Picker("本书日间", selection: Binding(
                            get: { store.preferences.resolvedBookThemeOverrides[bookId]?.dayPresetId },
                            set: { id in var all = store.preferences.resolvedBookThemeOverrides; var value = all[bookId] ?? .init(); value.enabled = true; value.dayPresetId = id; all[bookId] = value; store.preferences.bookThemeOverrides = all }
                        )) {
                            Text("跟随全局").tag(String?.none)
                            ForEach(store.preferences.resolvedThemePresets) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Picker("本书夜间", selection: Binding(
                            get: { store.preferences.resolvedBookThemeOverrides[bookId]?.nightPresetId },
                            set: { id in var all = store.preferences.resolvedBookThemeOverrides; var value = all[bookId] ?? .init(); value.enabled = true; value.nightPresetId = id; all[bookId] = value; store.preferences.bookThemeOverrides = all }
                        )) {
                            Text("跟随全局").tag(String?.none)
                            ForEach(store.preferences.resolvedThemePresets) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    NavigationLink("管理阅读主题") { ReaderThemePresetManagerView() }
                }
                Section("随读段评 · 本书") {
                    Toggle("本书单独设置", isOn: Binding(
                        get: { proactive.perBook[bookId]?.enabled ?? false },
                        set: { proactive.setBookOverride(bookId: bookId, enabled: $0) }
                    ))
                    if proactive.perBook[bookId]?.enabled == true {
                        let value = proactive.limits(for: bookId)
                        Stepper("每章至少 \(value.minPerChapter) 条", value: proactiveBookInt(\.minPerChapter, range: 0...10))
                        Picker("每章最多", selection: proactiveBookInt(\.maxPerChapter, range: -1...10)) {
                            ForEach(Array(1...10), id: \.self) { Text("\($0) 条").tag($0) }
                            Text("不限制").tag(ProactiveAnnotationLimits.unlimited)
                        }
                        Picker("每日最多", selection: proactiveBookInt(\.dailyMax, range: -1...50)) {
                            ForEach(Array(1...50), id: \.self) { Text("\($0) 条").tag($0) }
                            Text("不限制").tag(ProactiveAnnotationLimits.unlimited)
                        }
                        Picker("生成时机", selection: proactiveBookTiming()) {
                            ForEach(ProactiveAnnotationTiming.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        if value.timing == .onChapterEntry {
                            Stepper("提前 \(value.aheadChapters) 章", value: proactiveBookInt(\.aheadChapters, range: 0...5))
                        }
                    } else {
                        Text("当前跟随全局：\(proactive.limits(for: bookId).timing.label)，每章最多 \(proactive.limits(for: bookId).maxPerChapter == -1 ? "不限" : String(proactive.limits(for: bookId).maxPerChapter)) 条。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("自定义 CSS") { TextEditor(text: $store.preferences.customCSS).frame(minHeight: 120).font(.system(.caption, design: .monospaced)) }
            }.navigationTitle("阅读设置")
        }
    }

    private func proactiveBookInt(_ keyPath: WritableKeyPath<ProactiveAnnotationLimits, Int>, range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { proactive.limits(for: bookId)[keyPath: keyPath] },
            set: { newValue in
                var limits = proactive.limits(for: bookId)
                limits[keyPath: keyPath] = min(range.upperBound, max(range.lowerBound, newValue))
                proactive.setBookOverride(bookId: bookId, enabled: true, limits: limits)
            }
        )
    }

    private func proactiveBookTiming() -> Binding<ProactiveAnnotationTiming> {
        Binding(
            get: { proactive.limits(for: bookId).timing },
            set: { value in
                var limits = proactive.limits(for: bookId); limits.timing = value
                proactive.setBookOverride(bookId: bookId, enabled: true, limits: limits)
            }
        )
    }
}
