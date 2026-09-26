import SwiftUI

struct BookDetailSnapshot: Sendable {
    var chapters: [Chapter] = []
    var totalReadingMs: Int64 = 0
    var activeDays: Int = 0
    var bookmarkCount = 0
    var annotationCount = 0
    var noteCount = 0
    var readyAudiobookChapters = 0
    var scriptedAudiobookChapters = 0
}

actor BookDetailRepository {
    static let shared = BookDetailRepository()

    func snapshot(book: Book) async throws -> BookDetailSnapshot {
        async let chapters = LibraryRepository.shared.chapters(bookId: book.id)
        async let bookmarks = ReaderRecordRepository.shared.bookmarks(bookId: book.id)
        async let annotations = ReaderRecordRepository.shared.annotations(bookId: book.id)
        async let notes = NoteRepository.shared.notes(bookId: book.id)
        async let audiobook = AudiobookRepository.shared.chapterStates(bookId: book.id)
        let stats = try await ReadingStatsRepository.shared.snapshot()
        let values = try await (chapters, bookmarks, annotations, notes, audiobook)
        let bookDays = stats.daily.filter { $0.bookId == book.id && $0.durationMs > 0 }
        return BookDetailSnapshot(
            chapters: values.0,
            totalReadingMs: stats.byBook[book.id] ?? 0,
            activeDays: Set(bookDays.map(\.epochDay)).count,
            bookmarkCount: values.1.count,
            annotationCount: values.2.count,
            noteCount: values.3.count,
            readyAudiobookChapters: values.4.filter { $0.state == AudiobookChapterStatus.ready.rawValue }.count,
            scriptedAudiobookChapters: values.4.filter { $0.state != AudiobookChapterStatus.none.rawValue }.count
        )
    }
}

struct BookDetailView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let book: Book

    @State private var snapshot: BookDetailSnapshot?
    @State private var currentText = ""
    @State private var loadingText = false
    @State private var showCompanion = false
    @State private var showTools = false
    @State private var showAudiobook = false
    @State private var showManage = false
    @State private var showPlotSummary = false
    @State private var showCoverManager = false
    @State private var errorText: String?

    private var currentChapter: Chapter? {
        guard let chapters = snapshot?.chapters, !chapters.isEmpty else { return nil }
        return chapters.first(where: { $0.chapterIndex == book.lastReadChapterIndex }) ?? chapters.first
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular, showAudiobook, let snapshot, let chapter = currentChapter {
                HStack(spacing: 0) {
                    ScrollView { detailStack.frame(maxWidth: 430).padding(22).frame(maxWidth: .infinity) }
                        .frame(minWidth: 320, idealWidth: 390, maxWidth: 460)
                    Divider()
                    AudiobookStudioView(
                        book: book,
                        chapters: snapshot.chapters,
                        currentChapterIndex: chapter.chapterIndex,
                        currentChapterText: currentText
                    )
                    .environment(\.horizontalSizeClass, .compact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView { detailStack.frame(maxWidth: 900).padding(24).frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showManage = true } label: { Image(systemName: "slider.horizontal.3") }
                NavigationLink { ReaderView(book: book) } label: { Label("继续阅读", systemImage: "book.pages") }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showManage) { BookManageView(book: book).environmentObject(libraryStore) }
        .sheet(isPresented: $showPlotSummary) { PlotSummaryView(book: book) }
        .sheet(isPresented: $showCoverManager) { BookCoverManagerView(book: book).environmentObject(libraryStore) }
        .sheet(isPresented: $showCompanion) {
            if let chapter = currentChapter, !currentText.isEmpty {
                AICompanionView(book: book, chapter: chapter, chapterText: currentText,
                                visibleCharOffset: chapter.chapterIndex == book.lastReadChapterIndex ? book.lastReadCharOffset : 0)
            } else {
                ProgressView("正在载入当前章节…").task { await loadCurrentText() }
            }
        }
        .sheet(isPresented: $showTools) {
            if let snapshot, let chapter = currentChapter {
                ReaderToolsView(book: book, chapters: snapshot.chapters,
                                currentChapterIndex: chapter.chapterIndex,
                                currentChapterText: currentText,
                                currentOffset: chapter.chapterIndex == book.lastReadChapterIndex ? book.lastReadCharOffset : 0)
            }
        }
        .sheet(isPresented: Binding(get: { showAudiobook && horizontalSizeClass != .regular }, set: { if !$0 { showAudiobook = false } })) {
            if let snapshot, let chapter = currentChapter {
                NavigationStack {
                    AudiobookStudioView(book: book, chapters: snapshot.chapters, currentChapterIndex: chapter.chapterIndex, currentChapterText: currentText)
                        .navigationTitle("有声书 · \(book.title)")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showAudiobook = false } } }
                }
            }
        }
        .alert("读取失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { }
        } message: { Text(errorText ?? "") }
    }

    private var detailStack: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            progressCard
            if let snapshot { metrics(snapshot) }
            quickActions
            bookInformation
            if let snapshot { readingStatus(snapshot) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 22) {
            cover
            VStack(alignment: .leading, spacing: 9) {
                Text(book.title).font(.largeTitle.bold()).textSelection(.enabled)
                if !book.author.isEmpty { Text(book.author).font(.title3).foregroundStyle(.secondary) }
                HStack(spacing: 8) {
                    Label(book.format, systemImage: "doc")
                    Label("\(book.totalChapters) 章", systemImage: "list.number")
                    if book.pinnedAt > 0 { Label("置顶", systemImage: "pin.fill") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if !book.tags.isEmpty { Text(book.tags).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var cover: some View {
        if let path = book.coverPath, let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 120, height: 172).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12).fill(.secondary.opacity(0.12))
                .frame(width: 120, height: 172)
                .overlay { Image(systemName: "book.closed.fill").font(.system(size: 38)).foregroundStyle(.secondary) }
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(book.reachedEnd ? "已读完" : "阅读进度").font(.headline)
                Spacer()
                Text("\(book.progressPercent)%").font(.title3.monospacedDigit().bold())
            }
            ProgressView(value: book.progress)
            if let chapter = currentChapter {
                Text("上次读到：第 \(chapter.chapterIndex + 1) 章 · \(chapter.title)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            NavigationLink { ReaderView(book: book) } label: {
                Label(book.lastReadAt > 0 ? "继续阅读" : "开始阅读", systemImage: "book.pages.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(18).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func metrics(_ snapshot: BookDetailSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 12)], spacing: 12) {
            metric("阅读时长", duration(snapshot.totalReadingMs), "clock")
            metric("活跃天数", "\(snapshot.activeDays) 天", "calendar")
            metric("书签", "\(snapshot.bookmarkCount)", "bookmark")
            metric("划线 / 批注", "\(snapshot.annotationCount)", "highlighter")
            metric("笔记", "\(snapshot.noteCount)", "note.text")
            metric("有声书", "\(snapshot.readyAudiobookChapters) READY", "headphones")
        }
    }

    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint)
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这本书").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                action("AI 伴读", "sparkles") { Task { await openCompanion() } }
                action("大纲 / 人物 / 词典", "rectangle.3.group.bubble") { Task { await openTools() } }
                action("插图工作室", "photo.stack") { Task { await openTools() } }
                action(showAudiobook && horizontalSizeClass == .regular ? "收起有声书" : "有声书", "headphones") {
                    Task { await openAudiobook() }
                }
                NavigationLink { ReadingReviewView(initialBookId: book.id) } label: { actionLabel("回顾划线与笔记", "quote.bubble") }
                action("剧情梗概", "text.book.closed") { showPlotSummary = true }
                action("搜索 / 生成封面", "book.closed.fill") { showCoverManager = true }
                action("管理书籍", "slider.horizontal.3") { showManage = true }
            }
        }
    }

    private func action(_ title: String, _ icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { actionLabel(title, icon) }.buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.tint)
            Text(title).font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
        }
        .padding(13).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var bookInformation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("书籍信息").font(.headline)
            LabeledContent("格式", value: book.format)
            LabeledContent("章节", value: "\(book.totalChapters)")
            LabeledContent("总字符", value: book.totalChars > 0 ? "\(book.totalChars)" : "—")
            LabeledContent("导入时间", value: date(book.importedAt))
            LabeledContent("最近阅读", value: book.lastReadAt > 0 ? date(book.lastReadAt) : "尚未开始")
        }
        .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func readingStatus(_ snapshot: BookDetailSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("状态").font(.headline)
            HStack {
                Label(book.manualReadState.flatMap(BookReadState.init(rawValue:))?.label ?? (book.reachedEnd ? "已读完" : book.lastReadAt > 0 ? "在读" : "未读"), systemImage: "book")
                Spacer()
                if snapshot.scriptedAudiobookChapters > 0 {
                    Text("有声书已处理 \(snapshot.scriptedAudiobookChapters) 章").foregroundStyle(.secondary)
                }
            }
        }
        .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func reload() async {
        do {
            snapshot = try await BookDetailRepository.shared.snapshot(book: book)
            await loadCurrentText()
        } catch { errorText = error.localizedDescription }
    }

    private func loadCurrentText() async {
        guard let chapter = currentChapter, currentText.isEmpty, !loadingText else { return }
        loadingText = true
        do { currentText = try await LibraryRepository.shared.chapterText(chapter) }
        catch { errorText = error.localizedDescription }
        loadingText = false
    }

    private func openCompanion() async { await loadCurrentText(); if !currentText.isEmpty { showCompanion = true } }
    private func openTools() async { await loadCurrentText(); if !currentText.isEmpty { showTools = true } }
    private func openAudiobook() async {
        await loadCurrentText()
        guard !currentText.isEmpty else { return }
        if horizontalSizeClass == .regular { showAudiobook.toggle() }
        else { showAudiobook = true }
    }
    private func date(_ ms: Int64) -> String { Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .abbreviated, time: .shortened) }
    private func duration(_ ms: Int64) -> String {
        let minutes = ms / 60_000
        return minutes < 60 ? "\(minutes) 分" : String(format: "%.1f 小时", Double(minutes) / 60)
    }
}
