import SwiftUI
import UniformTypeIdentifiers

struct IllustrationStudioView: View {
    let book: Book
    let chapters: [Chapter]
    let currentChapterIndex: Int
    let currentChapterText: String
    let currentOffset: Int

    @State private var backend = "正在读取…"
    @State private var capabilities = ImageCapabilities()
    @State private var style = StyleSpec()
    @State private var templates: [ImageStyleTemplateRecord] = []
    @State private var looks: [LookSpec] = []
    @State private var assets: [ImageAssetRecord] = []
    @State private var images: [GeneratedIllustration] = []
    @State private var queue: [IllustrationQueueItem] = []
    @State private var characterNames: [String] = []
    @State private var preview: ImageRecipe?
    @State private var useReferences = true
    @State private var firstChapter = 0
    @State private var lastChapter = 0
    @State private var busy = false
    @State private var queueRunning = false
    @State private var importingAsset = false
    @State private var templateName = ""
    @State private var editingLook: LookSpec?
    @State private var turnaroundLook: LookSpec?
    @State private var newLookCharacter = ""
    @State private var errorText: String?

    private var maxChapter: Int { min(max(0, book.maxReachedChapterIndex), max(0, chapters.count - 1)) }
    private var sourceText: String {
        let scope = ReadingScope.upto(chapterIndex: book.maxReachedChapterIndex, charOffset: book.maxReachedCharOffset)
        return String(scope.readableText(chapterIndex: currentChapterIndex, text: currentChapterText).prefix(12_000))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                backendSection
                styleSection
                assetSection
                lookSection
                planSection
                batchSection
                generatedSection
            }
            .padding()
        }
        .task { await reloadAll() }
        .fileImporter(isPresented: $importingAsset, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            Task { await importAssets(result) }
        }
        .sheet(item: $editingLook) { look in
            LookEditorView(look: look, assets: assets) { updated in
                Task { await saveLook(updated) }
            }
        }
        .sheet(item: $turnaroundLook) { look in
            CharacterTurnaroundCandidatesView(book: book, chapterIndex: currentChapterIndex, look: look) { _ in
                await reloadLooks(); await reloadAssets(); await planCurrent()
            }
        }
        .alert("插图工作室", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { }
        } message: { Text(errorText ?? "") }
    }

    private var backendSection: some View {
        GroupBox("生图后端") {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Label(backend, systemImage: "sparkles.rectangle.stack"); Spacer(); if busy { ProgressView() } }
                Text(capabilitySummary).font(.caption).foregroundStyle(.secondary)
                if capabilities.characterReferenceCost > 0 {
                    Text("角色参考图每张可能产生额外服务费用；工作室会在计划中显示实际使用数量。")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var styleSection: some View {
        GroupBox("本书画风") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("预设", selection: $style.presetId) {
                    Text("水彩").tag("watercolor"); Text("厚涂").tag("painting"); Text("赛璐璐").tag("cel")
                    Text("水墨").tag("ink"); Text("铅笔").tag("pencil"); Text("绘本").tag("storybook")
                }
                TextField("自然语言画风", text: $style.natural, axis: .vertical).lineLimit(2...6)
                TextField("英文 / Danbooru 标签", text: $style.tags, axis: .vertical).lineLimit(2...5)
                TextField("负面提示词", text: $style.negative, axis: .vertical).lineLimit(2...4)
                HStack {
                    Text("参考强度"); Slider(value: $style.referenceStrength, in: 0...1); Text(style.referenceStrength.formatted(.number.precision(.fractionLength(2)))).monospacedDigit()
                }
                if capabilities.vibe {
                    HStack {
                        Text("Vibe 提取"); Slider(value: $style.informationExtracted, in: 0...1); Text(style.informationExtracted.formatted(.number.precision(.fractionLength(2)))).monospacedDigit()
                    }
                }
                if capabilities.seed {
                    TextField("Seed（可空）", text: Binding(
                        get: { style.seed.map(String.init) ?? "" },
                        set: { style.seed = Int64($0) }
                    )).keyboardType(.numberPad)
                }
                assetSelector(title: "画风参考图（最多 3 张）", selected: $style.referenceIds, limit: 3)
                HStack {
                    Button("保存本书画风") { Task { await saveStyle() } }.buttonStyle(.borderedProminent)
                    Spacer()
                    TextField("模板名", text: $templateName).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                    Button("存为模板") { Task { await saveTemplate() } }.disabled(templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !templates.isEmpty {
                    Divider(); Text("跨书模板").font(.subheadline.bold())
                    ForEach(templates) { template in
                        HStack {
                            Button(template.name) { style = template.style }.buttonStyle(.plain)
                            Spacer()
                            Button(role: .destructive) { Task { try? await ImageConsistencyRepository.shared.deleteTemplate(id: template.id); await reloadTemplates() } } label: { Image(systemName: "trash") }
                        }
                    }
                }
            }
        }
    }

    private var assetSection: some View {
        GroupBox("参考图库") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("参考图只保存本机资产 ID，不把图片字节或临时 URL 写进配方。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button { importingAsset = true } label: { Label("导入", systemImage: "plus") }
                }
                if assets.isEmpty { Text("还没有参考图").foregroundStyle(.secondary) }
                else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                        ForEach(assets) { item in
                            VStack(spacing: 5) {
                                if let ui = UIImage(contentsOfFile: item.filePath) {
                                    Image(uiImage: ui).resizable().scaledToFill().frame(height: 88).clipped().clipShape(RoundedRectangle(cornerRadius: 9))
                                }
                                Text(item.name).font(.caption2).lineLimit(1)
                                Button(role: .destructive) { Task { try? await ImageAssetLibrary.shared.delete(id: item.id); await reloadAssets() } } label: { Image(systemName: "trash").font(.caption) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var lookSection: some View {
        GroupBox("人物形象版本") {
            VStack(alignment: .leading, spacing: 10) {
                Text("同一人物可以从不同章节开始使用新的形象版本；生成某章插图时只会选择 sinceChapter 不晚于该章的版本。")
                    .font(.caption).foregroundStyle(.secondary)
                if !characterNames.isEmpty {
                    HStack {
                        Picker("人物", selection: $newLookCharacter) {
                            Text("选择人物").tag("")
                            ForEach(characterNames, id: \.self) { Text($0).tag($0) }
                        }
                        Button("新增版本") {
                            guard !newLookCharacter.isEmpty else { return }
                            editingLook = LookSpec(id: UUID().uuidString, characterKey: newLookCharacter, name: newLookCharacter, sinceChapter: currentChapterIndex)
                        }.disabled(newLookCharacter.isEmpty)
                    }
                }
                ForEach(looks, id: \.id) { look in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(look.name).font(.headline)
                            Text("从第 \(look.sinceChapter + 1) 章起 · \(look.referenceIds.count) 张参考图 · \(look.source)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(look.natural.isEmpty ? look.tags : look.natural).font(.caption).lineLimit(3)
                        }
                        Spacer()
                        Button("三视图") { turnaroundLook = look }
                        Button("编辑") { editingLook = look }
                        Button(role: .destructive) { Task { try? await ImageConsistencyRepository.shared.deleteLook(id: look.id); await reloadLooks() } } label: { Image(systemName: "trash") }
                    }
                }
            }
        }
    }

    private var planSection: some View {
        GroupBox("当前章计划") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("使用人物 / 画风参考图", isOn: $useReferences)
                HStack {
                    Button("预览章节计划") { Task { await planCurrent() } }
                    Button("生成当前章插图") { Task { await generateCurrent() } }.buttonStyle(.borderedProminent).disabled(busy || currentChapterIndex > maxChapter)
                }
                if let recipe = preview {
                    LabeledContent("后端", value: recipe.backend.isEmpty ? backend : recipe.backend)
                    LabeledContent("画布", value: recipe.size ?? "默认")
                    LabeledContent("人物", value: recipe.cast.map(\.name).joined(separator: "、").nilIfEmpty ?? "无")
                    LabeledContent("参考", value: "\(recipe.references.count) / \(capabilities.maxReferences)")
                    if let seed = recipe.seed { LabeledContent("Seed", value: "\(seed)") }
                    Text("镜头：\(recipe.shot.text)").font(.callout).textSelection(.enabled)
                    let plan = ImageRecipeLogic.planReferences(capabilities: capabilities, cast: recipe.cast, style: recipe.style, enabled: useReferences)
                    if !plan.notices.isEmpty { Text(plan.notices.map(noticeText).joined(separator: " · ")).font(.caption).foregroundStyle(.orange) }
                    if plan.extraCostPerImage > 0 { Text("角色参考附加成本单位：\(plan.extraCostPerImage)").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var batchSection: some View {
        GroupBox("批量生成已读章节") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Stepper("起：\(firstChapter + 1)", value: $firstChapter, in: 0...maxChapter)
                    Stepper("止：\(lastChapter + 1)", value: $lastChapter, in: firstChapter...maxChapter)
                }
                Text("一次最多 100 章。准备阶段只生成本地配方；真正付费请求按队列逐项执行，可暂停、继续和失败重试。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("准备并加入队列") { Task { await prepareBatch() } }.disabled(lastChapter - firstChapter >= 100 || busy)
                    if queueRunning { Button("暂停", role: .destructive) { Task { await IllustrationQueue.shared.pause(bookId: book.id); queueRunning = false; await reloadQueue() } } }
                    else { Button("开始 / 继续") { startQueue() }.disabled(queue.filter { $0.status == "pending" }.isEmpty) }
                }
                ForEach(queue) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chapters.indices.contains(row.chapterIndex) ? chapters[row.chapterIndex].title : "第 \(row.chapterIndex + 1) 章")
                            Text(queueLabel(row)).font(.caption).foregroundStyle(row.status == "failed" ? .red : .secondary)
                        }
                        Spacer()
                        if row.status == "failed" { Button("重试") { Task { try? await IllustrationQueue.shared.retry(id: row.id); await reloadQueue() } } }
                    }
                }
            }
        }
    }

    private var generatedSection: some View {
        GroupBox("已生成") {
            VStack(alignment: .leading, spacing: 10) {
                if images.isEmpty { Text("还没有插图").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(images) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            if let ui = UIImage(contentsOfFile: item.imagePath) {
                                Image(uiImage: ui).resizable().scaledToFill().frame(height: 170).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            Text(item.chapterIndex.map { "第 \($0 + 1) 章" } ?? "DIY").font(.caption.bold())
                            Text(item.prompt).font(.caption2).lineLimit(2)
                            HStack {
                                ShareLink(item: URL(fileURLWithPath: item.imagePath)) { Image(systemName: "square.and.arrow.up") }
                                Button { Task { await exportToPhotos(item) } } label: { Image(systemName: "photo.badge.arrow.down") }
                                Menu {
                                    Button { Task { await setAsCover(item) } } label: { Label("设为书籍封面", systemImage: "book.closed") }
                                    Button { Task { await exportToPhotos(item) } } label: { Label("保存到照片", systemImage: "photo.badge.arrow.down") }
                                    ShareLink(item: URL(fileURLWithPath: item.imagePath)) { Label("分享 / 存储到文件", systemImage: "square.and.arrow.up") }
                                    Divider()
                                    Button(role: .destructive) { Task { try? await ImageGenerationService.shared.delete(id: item.id); await reloadImages() } } label: { Label("删除", systemImage: "trash") }
                                } label: { Image(systemName: "ellipsis.circle") }
                                Spacer()
                                Button(role: .destructive) { Task { try? await ImageGenerationService.shared.delete(id: item.id); await reloadImages() } } label: { Image(systemName: "trash") }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func assetSelector(title: String, selected: Binding<[String]>, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold())
            if assets.isEmpty { Text("先在下方参考图库导入图片").font(.caption2).foregroundStyle(.secondary) }
            else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(assets) { item in
                            let active = selected.wrappedValue.contains(item.id)
                            Button {
                                var ids = selected.wrappedValue
                                if active { ids.removeAll { $0 == item.id } }
                                else if ids.count < limit { ids.append(item.id) }
                                selected.wrappedValue = ids
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    if let ui = UIImage(contentsOfFile: item.filePath) { Image(uiImage: ui).resizable().scaledToFill().frame(width: 72, height: 72).clipped().clipShape(RoundedRectangle(cornerRadius: 8)) }
                                    if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .blue).padding(4) }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var capabilitySummary: String {
        var values = ["参考图 \(capabilities.maxReferences)", "人物参考 \(capabilities.maxCharacterReferences)"]
        if capabilities.seed { values.append("Seed") }; if capabilities.vibe { values.append("Vibe") }; if capabilities.perCharacterPrompt { values.append("独立人物 Prompt") }
        return values.joined(separator: " · ")
    }
    private func noticeText(_ n: ReferenceNotice) -> String {
        switch n { case .textOnly: return "当前后端仅使用文字外貌"; case .primaryCharacterOnly: return "只保留主要人物参考"; case .referenceLimit: return "部分参考图超过上限"; case .vibeWithoutCharacter: return "角色参考与 Vibe 不能同时使用"; case .seedUnsupported: return "当前后端不支持 Seed" }
    }
    private func queueLabel(_ r: IllustrationQueueItem) -> String {
        switch r.status { case "pending": return "等待生成"; case "running": return "正在生成"; case "done": return "已完成"; case "failed": return "失败：\(r.error)"; default: return r.status }
    }

    @MainActor private func reloadAll() async {
        firstChapter = min(currentChapterIndex, maxChapter); lastChapter = min(currentChapterIndex, maxChapter)
        async let b = ImageGenerationService.shared.backendLabel(); async let c = ImageGenerationService.shared.capabilities()
        backend = await b; capabilities = await c
        await reloadStyle(); await reloadTemplates(); await reloadAssets(); await reloadLooks(); await reloadImages(); await reloadQueue(); await reloadCharacters()
    }
    @MainActor private func reloadStyle() async { style = (try? await ImageConsistencyRepository.shared.style(bookId: book.id)) ?? .init() }
    @MainActor private func reloadTemplates() async { templates = (try? await ImageConsistencyRepository.shared.templates()) ?? [] }
    @MainActor private func reloadAssets() async { assets = (try? await ImageAssetLibrary.shared.list()) ?? [] }
    @MainActor private func reloadLooks() async { looks = (try? await ImageConsistencyRepository.shared.looks(bookId: book.id)) ?? [] }
    @MainActor private func reloadImages() async { images = (try? await ImageGenerationService.shared.illustrations(bookId: book.id)) ?? [] }
    @MainActor private func reloadQueue() async { queue = (try? await IllustrationQueue.shared.items(bookId: book.id)) ?? [] }
    @MainActor private func reloadCharacters() async {
        let scope = ReadingScope.uptoProgress(book: book)
        characterNames = (try? await BookCharacterRepository.shared.published(bookId: book.id, scope: scope, allowBeyondProgress: false)?.characters.map(\.name)) ?? []
        if newLookCharacter.isEmpty { newLookCharacter = characterNames.first ?? "" }
    }
    @MainActor private func saveStyle() async { do { try await ImageConsistencyRepository.shared.saveStyle(bookId: book.id, style); await planCurrent() } catch { errorText = error.localizedDescription } }
    @MainActor private func saveTemplate() async { do { try await ImageConsistencyRepository.shared.saveTemplate(name: templateName, style: style); templateName = ""; await reloadTemplates() } catch { errorText = error.localizedDescription } }
    @MainActor private func saveLook(_ look: LookSpec) async { do { try await ImageConsistencyRepository.shared.saveLook(bookId: book.id, look); editingLook = nil; await reloadLooks(); await planCurrent() } catch { errorText = error.localizedDescription } }
    @MainActor private func planCurrent() async { busy = true; defer { busy = false }; do { preview = try await ImageConsistencyRepository.shared.plan(bookId: book.id, chapterIndex: currentChapterIndex, source: sourceText, useReferences: useReferences) } catch { errorText = error.localizedDescription } }
    @MainActor private func generateCurrent() async {
        busy = true; defer { busy = false }
        do {
            let recipe: ImageRecipe
            if let preview { recipe = preview }
            else { recipe = try await ImageConsistencyRepository.shared.plan(bookId: book.id, chapterIndex: currentChapterIndex, source: sourceText, useReferences: useReferences) }
            _ = try await ImageGenerationService.shared.generate(bookId: book.id, chapterIndex: currentChapterIndex, charOffset: currentOffset, sourceText: sourceText, recipe: recipe)
            preview = recipe
            await reloadImages()
        }
        catch { errorText = error.localizedDescription }
    }
    @MainActor private func prepareBatch() async {
        busy = true; defer { busy = false }
        do { let rows = try await IllustrationQueue.shared.prepare(bookId: book.id, first: firstChapter, last: lastChapter, useReferences: useReferences); try await IllustrationQueue.shared.enqueue(rows); await reloadQueue() }
        catch { errorText = error.localizedDescription }
    }
    @MainActor private func startQueue() {
        queueRunning = true
        Task {
            await IllustrationQueue.shared.start(bookId: book.id)
            await MainActor.run { queueRunning = false }
            await reloadQueue(); await reloadImages()
        }
    }
    @MainActor private func exportToPhotos(_ item: GeneratedIllustration) async {
        do { try await LocalImageExporter.shared.saveToPhotos(path: item.imagePath); errorText = "已保存到照片" }
        catch { errorText = error.localizedDescription }
    }
    @MainActor private func setAsCover(_ item: GeneratedIllustration) async {
        do { _ = try await LocalImageExporter.shared.setBookCover(book: book, imagePath: item.imagePath); errorText = "已设为书籍封面" }
        catch { errorText = error.localizedDescription }
    }

    @MainActor private func importAssets(_ result: Result<[URL], Error>) async {
        do { for url in try result.get() { _ = try await ImageAssetLibrary.shared.importImage(from: url) }; await reloadAssets() }
        catch { errorText = error.localizedDescription }
    }
}

private struct LookEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var look: LookSpec
    let assets: [ImageAssetRecord]
    let onSave: (LookSpec) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("显示名", text: $look.name)
                Stepper("从第 \(look.sinceChapter + 1) 章起", value: $look.sinceChapter, in: 0...100_000)
                TextField("外貌描述", text: $look.natural, axis: .vertical).lineLimit(3...8)
                TextField("英文 / Danbooru 标签", text: $look.tags, axis: .vertical).lineLimit(2...6)
                LabeledContent("参考强度") { Slider(value: $look.referenceStrength, in: 0...1) }
                LabeledContent("身份保真") { Slider(value: $look.fidelity, in: 0...1) }
                Section("人物参考图（最多 3 张）") {
                    ForEach(assets) { asset in
                        Toggle(isOn: Binding(
                            get: { look.referenceIds.contains(asset.id) },
                            set: { on in if on && look.referenceIds.count < 3 { look.referenceIds.append(asset.id) } else if !on { look.referenceIds.removeAll { $0 == asset.id } } }
                        )) { Text(asset.name) }
                    }
                }
            }
            .navigationTitle(look.name.isEmpty ? "人物形象" : look.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(look); dismiss() }.disabled(look.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
