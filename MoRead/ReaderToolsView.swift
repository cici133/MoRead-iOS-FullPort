import SwiftUI
import WebKit

private enum ReaderToolTab: String, CaseIterable, Identifiable {
    case outline = "大纲"
    case characters = "人物"
    case dictionary = "词典"
    case vocabulary = "生词"
    case illustrations = "插图"
    case audiobook = "有声书"
    var id: String { rawValue }
}

struct ReaderToolsView: View {
    let book: Book
    let chapters: [Chapter]
    let currentChapterIndex: Int
    let currentChapterText: String
    let currentOffset: Int
    var initialLookup: String = ""

    @Environment(\.dismiss) private var dismiss
    @State private var tab: ReaderToolTab = .outline
    @State private var knowledge: ChapterKnowledge?
    @State private var outlineKnowledge: [Int: ChapterKnowledge] = [:]
    @State private var outlineExpanded: Set<Int> = []
    @State private var outlineBusy: Set<Int> = []
    @State private var guide: BookCharacterGuide?
    @State private var lookup = ""
    @State private var definitions: [DictionaryDefinition] = []
    @State private var vocab: [VocabularyEntry] = []
    @State private var images: [GeneratedIllustration] = []
    @State private var roles: [AudiobookRole] = []
    @State private var segments: [AudiobookSegment] = []
    @State private var busy = false
    @State private var errorText: String?
    @State private var characterPlan: CharacterScanPlan?
    @State private var characterProgress: CharacterScanProgress?
    @State private var characterTask: Task<Void, Never>?
    @State private var confirmFullCharacterScan = false
    @State private var allowFullCharacterGuide = false
    @State private var characterSearch = ""
    @State private var evidenceTarget: EvidenceTarget?
    @State private var showTXTRechapter = false
    @State private var showTextCleanup = false

    private var scope: ReadingScope {
        .upto(chapterIndex: book.maxReachedChapterIndex, charOffset: book.maxReachedCharOffset)
    }

    var body: some View {
        NavigationStack {
            toolLayout
                .navigationTitle("阅读工具")
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } } }
                .task {
                    if !initialLookup.isEmpty { lookup = initialLookup; tab = .dictionary; await lookupWord() }
                    else { await loadCurrent() }
                }
                .onChange(of: tab) { _, _ in Task { await loadCurrent() } }
                .alert("操作失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                    Button("好", role: .cancel) { }
                } message: { Text(errorText ?? "") }
                .alert("扫描整本书的人物？", isPresented: $confirmFullCharacterScan, presenting: characterPlan) { plan in
                    Button("取消", role: .cancel) { characterPlan = nil }
                    Button("确认扫描未读内容", role: .destructive) { startCharacterScan(plan) }
                } message: { plan in
                    Text("这会把《\(plan.bookTitle)》全部 \(plan.chapterCount) 章（约 \(plan.sourceCharacters) 个 UTF-16 字符）发送给你配置的批量模型，可能包含尚未阅读的剧情。预计最多 \(plan.estimatedMaximumRequests) 次分段请求；本地已有 \(plan.reusableParts) 个可复用分段。只有点击确认后才会开始。")
                }
                .sheet(item: $evidenceTarget) { target in
                    NavigationStack { ReaderView(book: book, startChapterIndex: target.chapterIndex, startCharOffset: target.charOffset) }
                }
                .sheet(isPresented: $showTXTRechapter) { TXTRechapterView(book: book) }
                .sheet(isPresented: $showTextCleanup) { TextCleanupView(book: book) }
                .onDisappear { characterTask?.cancel() }
        }
    }

    @ViewBuilder private var toolLayout: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            NavigationSplitView {
                List {
                    ForEach(ReaderToolTab.allCases) { item in
                        Button { tab = item } label: {
                            HStack {
                                Text(item.rawValue)
                                Spacer()
                                if tab == item { Image(systemName: "checkmark") }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .navigationTitle("阅读工具")
            } detail: {
                content.padding()
            }
        } else {
            VStack(spacing: 0) {
                Picker("阅读工具", selection: $tab) {
                    ForEach(ReaderToolTab.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .pickerStyle(.segmented)
                .padding()
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .outline: outlineView
        case .characters: charactersView
        case .dictionary: dictionaryView
        case .vocabulary: vocabularyView
        case .illustrations: illustrationsView
        case .audiobook: audiobookView
        }
    }

    private var outlineView: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:12) {
                HStack {
                    Text("章节大纲").font(.headline)
                    Spacer()
                    Menu {
                        Button("生成所有缺失的已读章节") { Task { await generateMissingOutlines() } }
                        if book.sourceType.uppercased() == "TXT" { Button("重新识别章节") { showTXTRechapter = true } }
                        Button("永久应用正文净化") { showTextCleanup = true }
                    } label: { Image(systemName:"ellipsis.circle") }
                }
                Text("每章独立保存；最多同时进行两个模型请求。当前阅读水位之后的章节不会发送给模型。")
                    .font(.footnote).foregroundStyle(.secondary)

                ForEach(chapters) { chapter in
                    let readable = chapter.chapterIndex <= book.maxReachedChapterIndex
                    DisclosureGroup(isExpanded:Binding(get:{outlineExpanded.contains(chapter.chapterIndex)},set:{expanded in
                        if expanded { outlineExpanded.insert(chapter.chapterIndex); Task { await loadOutline(chapter.chapterIndex) } }
                        else { outlineExpanded.remove(chapter.chapterIndex) }
                    })) {
                        VStack(alignment:.leading,spacing:10) {
                            if !readable {
                                Label("尚未读到这一章，防剧透范围内不可生成。",systemImage:"lock.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if outlineBusy.contains(chapter.chapterIndex) {
                                HStack { ProgressView(); Text("正在整理本章…").foregroundStyle(.secondary) }
                            } else if let item=outlineKnowledge[chapter.chapterIndex] {
                                Text(item.readableOutline).textSelection(.enabled)
                                if !item.summary.isEmpty {
                                    Divider();Text("原文依据").font(.caption.bold())
                                    ForEach(Array(item.summary.enumerated()),id:\.offset) { _,fact in
                                        Button { evidenceTarget = .init(chapterIndex:chapter.chapterIndex,charOffset:fact.start) } label:{
                                            VStack(alignment:.leading,spacing:3){Text(fact.text).font(.caption);Text("“\(fact.quote)”").font(.caption2).foregroundStyle(.secondary).lineLimit(3)}
                                                .frame(maxWidth:.infinity,alignment:.leading)
                                        }.buttonStyle(.plain)
                                    }
                                }
                                Button("重新生成本章") { Task { await generateOutline(chapter.chapterIndex) } }.buttonStyle(.bordered)
                            } else {
                                ContentUnavailableView("还没有本章大纲",systemImage:"list.bullet.rectangle",description:Text("只会读取这一章在当前已读范围内可见的正文。"))
                                Button("生成本章") { Task { await generateOutline(chapter.chapterIndex) } }.buttonStyle(.borderedProminent)
                            }
                        }.padding(.top,8)
                    } label:{
                        HStack {
                            VStack(alignment:.leading,spacing:2){Text(chapter.title.isEmpty ? "第 \(chapter.chapterIndex+1) 章":chapter.title);Text("第 \(chapter.chapterIndex+1) 章").font(.caption2).foregroundStyle(.secondary)}
                            Spacer()
                            if outlineBusy.contains(chapter.chapterIndex){ProgressView().controlSize(.small)}
                            else if outlineKnowledge[chapter.chapterIndex] != nil { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green) }
                            else if !readable { Image(systemName:"lock").foregroundStyle(.secondary) }
                        }
                    }
                    .padding(12).background(.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:14))
                }
            }.padding()
        }
    }

    private var charactersView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Text("人物资料").font(.headline)
                    Spacer()
                    if characterTask != nil {
                        Button("停止", role: .destructive) { characterTask?.cancel(); characterTask = nil; busy = false }
                    } else {
                        Menu {
                            Button(guide == nil ? "提取到当前进度" : "更新到当前进度") { Task { await prepareCharacterScan(progressBounded: true) } }
                            Button("扫描整本书（包含未读）") { Task { await prepareCharacterScan(progressBounded: false) } }
                        } label: { Label("提取", systemImage: "person.3.sequence") }
                        .disabled(busy)
                    }
                }
                TextField("查找人物", text: $characterSearch).textFieldStyle(.roundedBorder)
                if let progress = characterProgress, characterTask != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.chapterNumber), total: Double(max(1, progress.chapterCount)))
                        Text("第 \(progress.chapterNumber)/\(progress.chapterCount) 章 · \(progress.chapterTitle) · 已处理 \(progress.completedParts) 段（复用 \(progress.reusedParts) 段）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if busy && guide == nil { ProgressView() }
                if let g = guide {
                    if g.progressBounded == false {
                        Label("这份人物资料来自整本书，包含未读章节。", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    let people = g.characters.filter { characterSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(characterSearch) || $0.facts.contains { $0.text.localizedCaseInsensitiveContains(characterSearch) } }
                    ForEach(people, id: \.name) { c in
                        DisclosureGroup(c.name) {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(c.facts, id: \.self) { f in Text(f.text) }
                                ForEach(c.attributes, id: \.self) { a in Text("\(a.kind.rawValue)：\(a.value)").font(.callout) }
                                ForEach(c.relationships, id: \.self) { r in Text("→ \(r.target)：\(r.relation)").font(.callout) }
                                if let evidence = g.evidenceByName?[c.name], !evidence.isEmpty {
                                    Divider()
                                    Text("原文依据").font(.caption.bold())
                                    ForEach(Array(evidence.prefix(8).enumerated()), id: \.offset) { _, row in
                                        Button { evidenceTarget = .init(chapterIndex: row.chapterIndex, charOffset: row.fact.start) } label: {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text("第 \(row.chapterIndex + 1) 章 · \(row.fact.text)").font(.caption)
                                                Text("“\(row.fact.quote)”").font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }.padding(.vertical, 6)
                        }
                    }
                } else if characterTask == nil {
                    ContentUnavailableView("还没有人物资料", systemImage: "person.3", description: Text("默认只提取已读范围。扫描未读章节必须单独确认。"))
                }
            }.padding()
        }
    }

    private var dictionaryView: some View {
        VStack(spacing: 10) {
            HStack {
                TextField("输入或粘贴词语", text: $lookup).textFieldStyle(.roundedBorder)
                Button("查词") { Task { await lookupWord() } }.disabled(lookup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal)
            if definitions.isEmpty {
                ContentUnavailableView("本地 MDX / MDD 词典", systemImage: "character.book.closed", description: Text("在设置中导入词典后，可在这里或阅读选区查词。"))
            } else {
                List(definitions) { d in
                    Section(d.title) {
                        DictionaryHTMLView(dictionaryId: d.dictionaryId, html: d.html) { word in
                            lookup = word
                            Task { await lookupWord() }
                        }
                        .frame(minHeight: 180)
                    }
                }
            }
        }
    }

    private var vocabularyView: some View {
        List {
            ForEach(vocab) { v in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(v.word).font(.headline)
                        if !v.phonetic.isEmpty { Text(v.phonetic).foregroundStyle(.secondary) }
                        Spacer(); if v.learned { Image(systemName: "checkmark.circle.fill") }
                    }
                    Text(v.shortGloss.isEmpty ? v.definitionMarkdown : v.shortGloss).font(.callout)
                }
            }
            .onDelete { set in
                Task {
                    for i in set where vocab.indices.contains(i) { try? await VocabularyRepository.shared.remove(word: vocab[i].word) }
                    await loadVocabulary()
                }
            }
        }
    }

    private var illustrationsView: some View {
        IllustrationStudioView(
            book: book, chapters: chapters, currentChapterIndex: currentChapterIndex,
            currentChapterText: currentChapterText, currentOffset: currentOffset
        )
    }

    private var audiobookView: some View {
        AudiobookStudioView(
            book: book, chapters: chapters, currentChapterIndex: currentChapterIndex,
            currentChapterText: currentChapterText
        )
    }

    @MainActor private func loadCurrent() async {
        do {
            switch tab {
            case .outline:
                outlineExpanded.insert(currentChapterIndex)
                await loadOutline(currentChapterIndex)
                knowledge = outlineKnowledge[currentChapterIndex]
            case .characters:
                allowFullCharacterGuide = UserDefaults.standard.bool(forKey: "moread.characters.full-consent.\(book.id)")
                guide = try await BookCharacterRepository.shared.published(bookId: book.id, scope: scope, allowBeyondProgress: allowFullCharacterGuide)
            case .vocabulary: await loadVocabulary()
            case .illustrations: images = try await ImageGenerationService.shared.illustrations(bookId: book.id)
            case .audiobook: break
            case .dictionary: break
            }
        } catch { errorText = error.localizedDescription }
    }
    @MainActor private func loadOutline(_ chapterIndex:Int) async {
        guard chapterIndex <= book.maxReachedChapterIndex, outlineKnowledge[chapterIndex] == nil else { return }
        do {
            if let value = try await ChapterKnowledgeRepository.shared.knowledge(bookId:book.id,chapterIndex:chapterIndex,scope:scope) {
                outlineKnowledge[chapterIndex]=value
                if chapterIndex == currentChapterIndex { knowledge=value }
            }
        } catch { errorText=error.localizedDescription }
    }

    @MainActor private func generateOutline(_ chapterIndex:Int) async {
        guard chapterIndex <= book.maxReachedChapterIndex, !outlineBusy.contains(chapterIndex) else { return }
        outlineBusy.insert(chapterIndex)
        await ChapterOutlineLimiter.shared.acquire()
        do {
            let value = try await ChapterKnowledgeRepository.shared.generate(bookId:book.id,chapterIndex:chapterIndex,scope:scope)
            outlineKnowledge[chapterIndex]=value
            if chapterIndex == currentChapterIndex { knowledge=value }
        } catch { errorText=error.localizedDescription }
        await ChapterOutlineLimiter.shared.release()
        outlineBusy.remove(chapterIndex)
    }

    @MainActor private func generateMissingOutlines() async {
        let targets=chapters.map(\.chapterIndex).filter { $0 <= book.maxReachedChapterIndex && outlineKnowledge[$0] == nil && !outlineBusy.contains($0) }
        for index in targets { Task { await generateOutline(index) } }
    }

    @MainActor private func generateKnowledge() async { await generateOutline(currentChapterIndex) }
    @MainActor private func prepareCharacterScan(progressBounded: Bool) async {
        busy = true
        do {
            let plan = try await BookCharacterRepository.shared.preview(bookId: book.id, progressBounded: progressBounded)
            characterPlan = plan
            if progressBounded { startCharacterScan(plan) }
            else { confirmFullCharacterScan = true; busy = false }
        } catch { busy = false; errorText = error.localizedDescription }
    }

    @MainActor private func startCharacterScan(_ plan: CharacterScanPlan) {
        characterTask?.cancel()
        busy = true
        characterProgress = nil
        characterTask = Task {
            do {
                let result = try await BookCharacterRepository.shared.extract(plan: plan) { progress in
                    await MainActor.run { characterProgress = progress }
                }
                if !plan.progressBounded {
                    UserDefaults.standard.set(true, forKey: "moread.characters.full-consent.\(book.id)")
                    allowFullCharacterGuide = true
                }
                guide = result
            } catch is CancellationError {
                // Verified part cache is intentionally retained for resume.
            } catch { errorText = error.localizedDescription }
            busy = false; characterTask = nil; characterPlan = nil
        }
    }
    @MainActor private func lookupWord() async { do { definitions = try await LocalDictionaryRepository.shared.lookup(lookup.trimmingCharacters(in: .whitespacesAndNewlines)) } catch { errorText = error.localizedDescription } }
    @MainActor private func loadVocabulary() async { do { vocab = try await VocabularyRepository.shared.list() } catch { errorText = error.localizedDescription } }



}

private actor ChapterOutlineLimiter {
    static let shared = ChapterOutlineLimiter()
    private var running=0
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    func acquire() async {
        if running < 2 { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if !waiters.isEmpty { waiters.removeFirst().resume() }
        else { running=max(0,running-1) }
    }
}

private final class DictionaryResourceSchemeHandler: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
    typealias Lookup = @MainActor (String) -> Void
    let onLookup: Lookup
    init(onLookup: @escaping Lookup) { self.onLookup = onLookup }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let host = url.host?.removingPercentEncoding, !host.isEmpty else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        let resourcePath = url.path.removingPercentEncoding ?? url.path
        Task {
            do {
                guard let data = try await LocalDictionaryRepository.shared.resource(dictionaryId: host, path: resourcePath) else {
                    let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Cache-Control":"no-store", "X-Content-Type-Options":"nosniff"])!
                    urlSchemeTask.didReceive(response); urlSchemeTask.didFinish(); return
                }
                let response = URLResponse(url: url, mimeType: Self.mimeType(for: resourcePath), expectedContentLength: data.count, textEncodingName: Self.textEncoding(for: resourcePath))
                urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch { urlSchemeTask.didFailWithError(error) }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "entry" {
            let raw = url.absoluteString.replacingOccurrences(of: "entry://", with: "")
            let word = (raw.removingPercentEncoding ?? raw).split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            if !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { @MainActor in self.onLookup(word) }
            }
            decisionHandler(.cancel); return
        }
        if scheme == "moread-dict" || scheme == "about" { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }

    private static func textEncoding(for path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() { case "css", "html", "htm", "txt": return "utf-8"; default: return nil }
    }
    private static func mimeType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "css": return "text/css"
        case "html", "htm": return "text/html"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "mp4", "m4a": return "audio/mp4"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}

private struct DictionaryHTMLView: UIViewRepresentable {
    let dictionaryId: String
    let html: String
    var onLookup: @MainActor (String) -> Void

    func makeCoordinator() -> DictionaryResourceSchemeHandler { DictionaryResourceSchemeHandler(onLookup: onLookup) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "moread-dict")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let safeId = dictionaryId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? dictionaryId
        let base = URL(string: "moread-dict://\(safeId)/")
        let clean = Self.sanitize(html)
        let wrapper = """
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <meta http-equiv='Content-Security-Policy' content="default-src 'none'; img-src moread-dict: data:; style-src 'unsafe-inline' moread-dict:; font-src moread-dict:; media-src moread-dict:;">
        <style>body{font:-apple-system-body;margin:0;background:transparent;color:CanvasText;overflow-wrap:anywhere;line-height:1.6}img,svg,video{max-width:100%;height:auto}audio{max-width:100%}table{max-width:100%}a{color:LinkText}</style>
        \(clean)
        """
        view.loadHTMLString(wrapper, baseURL: base)
    }

    private static func sanitize(_ source: String) -> String {
        var value = String(source.prefix(2_000_000))
        let patterns = [
            #"(?is)<(script|iframe|frame|object|embed|form|base)[^>]*>.*?</\1>"#,
            #"(?is)<(script|iframe|frame|object|embed|form|base)[^>]*/?>"#,
            #"(?is)<meta[^>]+http-equiv[^>]*>"#,
            #"(?is)\s+on[a-z0-9_-]+\s*=\s*([\"']).*?\1"#,
            #"(?is)\s+on[a-z0-9_-]+\s*=\s*[^\s>]+"#
        ]
        for pattern in patterns { value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
        return value
    }
}


private struct EvidenceTarget: Identifiable {
    let id = UUID()
    let chapterIndex: Int
    let charOffset: Int
}
