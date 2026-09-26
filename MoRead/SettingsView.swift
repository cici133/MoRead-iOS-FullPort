import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        NavigationStack {
            List {
                Section("AI 与伴读") {
                    NavigationLink {
                        AIServiceSettingsView()
                    } label: {
                        SettingsRow(icon: "sparkles", title: "AI 服务", subtitle: "多 Provider、模型能力与角色分配")
                    }
                    NavigationLink {
                        CompanionAutonomySettingsView()
                    } label: {
                        SettingsRow(icon: "wand.and.rays", title: "伴读自主行为", subtitle: "多气泡、自主语音与自主插图总闸")
                    }
                    NavigationLink {
                        ProactiveSettingsView()
                    } label: {
                        SettingsRow(icon: "quote.bubble", title: "随读段评", subtitle: "角色、数量、每日额度与上下文预算")
                    }
                    NavigationLink {
                        ImageGenerationSettingsView()
                    } label: {
                        SettingsRow(icon: "photo.badge.plus", title: "生图服务", subtitle: "OpenAI Images / Chat 出图 / NovelAI 与参考图")
                    }
                    NavigationLink {
                        WebSearchSettingsView()
                    } label: {
                        SettingsRow(icon: "globe", title: "网络搜索", subtitle: "Firecrawl / Exa / Tavily，供伴读查询书外知识")
                    }
                    NavigationLink {
                        UserMaskSettingsView()
                    } label: {
                        SettingsRow(icon: "person.text.rectangle", title: "用户面具", subtitle: "管理对话中的用户侧身份")
                    }
                    NavigationLink {
                        CompanionMemorySettingsView()
                    } label: {
                        SettingsRow(icon: "brain.head.profile", title: "伴读记忆", subtitle: "长期记忆、跨书记忆与跨书检索")
                    }
                    NavigationLink {
                        GlobalPromptSettingsView()
                    } label: {
                        SettingsRow(icon: "text.quote", title: "全局预设", subtitle: "按位置注入自定义提示词，不改写原消息")
                    }
                }

                Section("阅读工具") {
                    NavigationLink {
                        DictionarySettingsView()
                    } label: {
                        SettingsRow(icon: "character.book.closed", title: "本地词典", subtitle: "MDX / MDD 导入、启停与资源包")
                    }
                    NavigationLink {
                        ReaderGlobalSettingsView()
                    } label: {
                        SettingsRow(icon: "textformat.size", title: "阅读与外观", subtitle: "翻页、排版、点击区域、繁简与自动阅读")
                    }
                    NavigationLink {
                        SpeechSettingsView()
                    } label: {
                        SettingsRow(icon: "waveform", title: "语音朗读", subtitle: "系统 TTS、云 TTS、缓存与合成策略")
                    }
                    NavigationLink {
                        VoiceDesignView()
                    } label: {
                        SettingsRow(icon: "person.wave.2", title: "音色设计", subtitle: "Gemini 自定义音色、试听与 AI 辅助设定")
                    }
                    NavigationLink {
                        ReviewShareTemplateSettingsView()
                    } label: {
                        SettingsRow(icon: "rectangle.and.pencil.and.ellipsis", title: "回顾分享模板", subtitle: "Markdown 与图片卡片的独立样式")
                    }
                    NavigationLink { FontLibraryView() } label: {
                        SettingsRow(icon: "textformat", title: "字体库", subtitle: "App 字体、阅读字体与章首字体共用资产")
                    }
                    NavigationLink { ImageLibraryView() } label: {
                        SettingsRow(icon: "photo.on.rectangle", title: "图片库", subtitle: "阅读背景、封面、参考图与分享模板共用资产")
                    }
                }

                Section("数据") {
                    NavigationLink {
                        LANTransferSettingsView()
                    } label: {
                        SettingsRow(icon: "wifi", title: "局域网传书", subtitle: "电脑浏览器上传 TXT / EPUB")
                    }
                    NavigationLink {
                        BackupSettingsView()
                    } label: {
                        SettingsRow(icon: "arrow.triangle.2.circlepath.icloud", title: "备份与恢复", subtitle: "WebDAV 完整/轻量备份与本地恢复")
                    }
                    NavigationLink {
                        StorageSettingsView()
                    } label: {
                        SettingsRow(icon: "internaldrive", title: "存储", subtitle: "正文、语音缓存、插图与保留记录")
                    }
                }

                Section("应用") {
                    NavigationLink { AppAppearanceSettingsView() } label: { SettingsRow(icon:"circle.lefthalf.filled",title:"应用外观",subtitle:"语言、跟随系统 / 浅色 / 深色") }
                    NavigationLink { APILogView() } label: { SettingsRow(icon:"list.bullet.rectangle",title:"API 调用日志",subtitle:"接口、状态、耗时与流量；不记录正文和密钥") }
                    NavigationLink { DiagnosticsView() } label: { SettingsRow(icon:"stethoscope",title:"关于与诊断",subtitle:"数据库、存储、AI、备份与平台适配检查") }
                    NavigationLink { LegalNoticesView() } label: { SettingsRow(icon:"doc.text",title:"开源许可",subtitle:"GPL-3.0 与 iOS 第三方依赖说明") }
                }

                Section("关于") {
                    LabeledContent("数据库", value: "schema 32")
                    LabeledContent("平台", value: "iOS / iPadOS")
                    LabeledContent("数据方式", value: "本地存储 · BYOK")
                    Text("iOS 端保持与 Android 版相同的数据语义和功能边界；底层系统能力使用 Apple 平台对应实现。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}

private struct SettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ReaderGlobalSettingsView: View {
    @ObservedObject private var store = ReaderSettingsStore.shared

    var body: some View {
        Form {
            Section("阅读方式") {
                Picker("模式", selection: $store.preferences.layoutMode) {
                    Text("分页").tag(ReaderLayoutMode.paged)
                    Text("滚动").tag(ReaderLayoutMode.scroll)
                }
                Picker("文字方向", selection: $store.preferences.writingMode) {
                    Text("横排").tag(ReaderWritingMode.horizontal)
                    Text("竖排").tag(ReaderWritingMode.vertical)
                }
                Picker("翻页效果", selection: $store.preferences.pageAnimation) {
                    ForEach(ReaderPageAnimation.allCases, id: \.self) { value in
                        Text(animationLabel(value)).tag(value)
                    }
                }
                Toggle("宽屏双页", isOn: $store.preferences.twoPageSpread)
                Picker("EPUB 出版方样式", selection: $store.preferences.publisherStyleMode) {
                    ForEach(ReaderPublisherStyleMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }

            Section("外观与规则") {
                NavigationLink("主题、字体与背景") { ReaderAppearanceAdvancedView() }
                NavigationLink("正文净化、语法高亮与章首") { ReaderEnhancementSettingsView() }
            }

            Section("排版") {
                LabeledContent("字号") { Slider(value: $store.preferences.fontSize, in: 14...38, step: 1) }
                LabeledContent("行距") { Slider(value: $store.preferences.lineHeight, in: 1.1...2.4, step: 0.05) }
                LabeledContent("横向页边距") { Slider(value: $store.preferences.horizontalMargin, in: 8...64, step: 1) }
                LabeledContent("纵向页边距") { Slider(value: $store.preferences.verticalMargin, in: 8...64, step: 1) }
                Toggle("显示已保存译文", isOn: $store.preferences.showTranslations)
                Text("繁简转换按书单独保存，在阅读页 → 阅读设置中选择 TW2SP / S2TWP；这样一本书的转换不会影响其他书。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("自动阅读") {
                Picker("方式", selection: $store.preferences.autoRead.mode) {
                    Text("匀速滚动").tag(PageMode.scroll)
                    Text("定时翻页").tag(PageMode.page)
                }
                LabeledContent("滚动速度") { Slider(value: $store.preferences.autoRead.scrollDpPerSecond, in: 8...96, step: 1) }
                Stepper("定时翻页：\(store.preferences.autoRead.pageIntervalSeconds) 秒", value: $store.preferences.autoRead.pageIntervalSeconds, in: 3...120)
                Toggle("显示屏幕参考线", isOn: $store.preferences.autoRead.showGuide)
            }

            Section("点击区域") {
                NavigationLink("配置 13 区点击动作") { TapZoneSettingsView(store: store) }
                NavigationLink("外接键盘翻页") { PhysicalKeySettingsView(store: store) }
            }
        }
        .navigationTitle("阅读与外观")
    }

    private func animationLabel(_ value: ReaderPageAnimation) -> String {
        switch value {
        case .none: return "无动画"
        case .slide: return "滑动"
        case .cover: return "覆盖"
        case .classicCurl: return "经典仿真"
        case .modernCurl: return "现代仿真"
        }
    }
}

private struct TapZoneSettingsView: View {
    @ObservedObject var store: ReaderSettingsStore
    var body: some View {
        List {
            ForEach(0..<13, id: \.self) { index in
                Picker(zoneName(index), selection: Binding(
                    get: { store.preferences.tapZones.actions[index] },
                    set: { value in
                        var zones = store.preferences.tapZones
                        zones.actions[index] = value
                        if zones.actions.contains(.menu) { store.preferences.tapZones = zones }
                    }
                )) {
                    ForEach(ReaderTapAction.allCases, id: \.self) { action in
                        Text(action.label).tag(action)
                    }
                }
            }
        }
        .navigationTitle("点击区域")
    }

    private func zoneName(_ i: Int) -> String {
        if i < 9 { return "正文 \(i / 3 + 1)-\(i % 3 + 1)" }
        if i < 11 { return i == 9 ? "页眉左" : "页眉右" }
        return i == 11 ? "页脚左" : "页脚右"
    }
}

private struct PhysicalKeySettingsView: View {
    @ObservedObject var store: ReaderSettingsStore
    var body: some View {
        List {
            Section("外接键盘动作") {
                ForEach(ReaderHardwareKey.allCases, id: \.self) { key in
                    Picker(key.label, selection: Binding(
                        get: { store.preferences.keyBindings.actions[key] ?? .none },
                        set: { store.preferences.keyBindings.actions[key] = $0 }
                    )) {
                        ForEach(ReaderTapAction.allCases, id: \.self) { action in
                            Text(action.label).tag(action)
                        }
                    }
                }
            }
            Section {
                Label("锁屏与耳机媒体键用于听书播放控制", systemImage: "headphones")
                Text("iOS 不允许第三方应用全局拦截实体音量键，因此音量键仍由系统调节音量；其余外接键盘翻页动作可在上方逐键配置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("物理按键")
    }
}

struct StorageSettingsView: View {
    @State private var snapshot = StorageSnapshot(categories: [], books: [])
    @State private var loading = true
    @State private var errorText: String?
    @State private var confirm: StorageAction?
    @State private var reclaimed: Int64?

    private enum StorageAction: Identifiable {
        case removeBody(BookStorageUsage), permanent(BookStorageUsage)
        var id: String { switch self { case .removeBody(let b): "body-\(b.id)"; case .permanent(let b): "all-\(b.id)" } }
    }

    var body: some View {
        List {
            if loading { ProgressView().frame(maxWidth: .infinity) }
            Section("占用") {
                ForEach(snapshot.categories) { row in
                    LabeledContent(row.name, value: ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))
                }
            }
            Section("安全清理") {
                Button("清理全部语音缓存") { run { try await StorageRepository.shared.clearSpeech() } }
                Button("清理可重建向量索引") { run { try await StorageRepository.shared.clearIndexes() } }
                Button("清理临时导出") { run { try await StorageRepository.shared.clearExports() } }
                Button("查找并清理孤儿文件") {
                    run {
                        reclaimed = try await StorageRepository.shared.cleanupOrphans()
                    }
                }
                if let reclaimed { Text("上次深度清理释放 \(ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file))").font(.footnote).foregroundStyle(.secondary) }
            }
            Section("按书管理") {
                ForEach(snapshot.books) { book in
                    NavigationLink {
                        BookStorageDetailView(book: book) { Task { await reload() } }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(book.title).lineLimit(1); if book.removed { Text("仅保留记录").font(.caption2).foregroundStyle(.secondary) } }
                            Text(ByteCountFormatter.string(fromByteCount: book.totalBytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Text("“移除正文”只删除可重建的书籍内容、索引和本书语音，阅读统计、书签、批注、笔记与伴读历史继续保留；“永久删除”才会同时删除这些个人记录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("存储")
        .task { await reload() }
        .refreshable { await reload() }
        .alert("存储操作失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorText ?? "") }
    }

    private func reload() async {
        loading = true
        do { snapshot = try await StorageRepository.shared.snapshot() } catch { errorText = error.localizedDescription }
        loading = false
    }
    private func run(_ operation: @escaping @Sendable () async throws -> Void) {
        Task { do { try await operation(); await reload() } catch { await MainActor.run { errorText = error.localizedDescription } } }
    }
}

private struct BookStorageDetailView: View {
    let book: BookStorageUsage
    let onChanged: () -> Void
    @State private var confirmPermanent = false
    @State private var confirmRemove = false
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("占用") {
                LabeledContent("正文与原书", value: bytes(book.contentBytes))
                LabeledContent("语音缓存", value: bytes(book.speechBytes))
                LabeledContent("插图", value: bytes(book.illustrationBytes))
                LabeledContent("附件", value: bytes(book.attachmentBytes))
            }
            Section("可重建数据") {
                Button("清除此书语音缓存") { execute { try await StorageRepository.shared.clearSpeech(bookId: book.id) } }
                Button("清除此书向量索引") { execute { try await StorageRepository.shared.clearIndexes(bookId: book.id) } }
            }
            Section("书籍数据") {
                if !book.removed { Button("移除正文但保留个人记录", role: .destructive) { confirmRemove = true } }
                Button("永久删除书籍与全部个人记录", role: .destructive) { confirmPermanent = true }
            }
        }
        .navigationTitle(book.title)
        .confirmationDialog("移除正文？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("移除正文，保留记录", role: .destructive) { executeAndDismiss { try await StorageRepository.shared.removeBodyKeepingRecords(bookId: book.id) } }
        } message: { Text("统计、书签、批注、笔记和伴读历史会保留；正文、原 EPUB、索引和本书语音会清理。") }
        .confirmationDialog("永久删除？", isPresented: $confirmPermanent, titleVisibility: .visible) {
            Button("永久删除", role: .destructive) { executeAndDismiss { try await StorageRepository.shared.permanentlyDelete(bookId: book.id) } }
        } message: { Text("此操作会删除正文以及这本书的统计、批注、笔记、伴读、插图和其他个人记录，无法撤销。") }
        .alert("操作失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorText ?? "") }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func execute(_ op: @escaping @Sendable () async throws -> Void) { Task { do { try await op(); onChanged() } catch { errorText = error.localizedDescription } } }
    private func executeAndDismiss(_ op: @escaping @Sendable () async throws -> Void) { Task { do { try await op(); onChanged(); dismiss() } catch { errorText = error.localizedDescription } } }
}

