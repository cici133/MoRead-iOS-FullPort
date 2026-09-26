import AVFoundation
import SwiftUI

struct AICompanionView: View {
    let book: Book
    var embedded: Bool = false
    let chapter: Chapter
    let chapterText: String
    let visibleCharOffset: Int
    var initialDraft: String = ""
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = AIChatSession()
    @State private var input = ""
    @State private var showSessions = false
    @State private var personas: [PersonaRecord] = []
    @State private var selectedPersonaId: Int64?
    @State private var suggestions: [String] = []
    @State private var suggesting = false
    @State private var chatAppearance = PersonaChatAppearance()
    @State private var chatBackgroundPath: String?
    @State private var editingBubble: CompanionBubble?
    @State private var editText = ""
    @ObservedObject private var autonomy = CompanionAutonomySettingsStore.shared
    @ObservedObject private var webSearch = WebSearchSettingsStore.shared
    @ObservedObject private var memorySettings = CompanionMemorySettingsStore.shared

    private var scope: ReadingScope {
        guard autonomy.spoilerProtectionEnabled else { return .wholeBook }
        let reached = ReadingScope.upto(chapterIndex: book.maxReachedChapterIndex, charOffset: book.maxReachedCharOffset)
        let visible = ReadingScope.upto(chapterIndex: chapter.chapterIndex, charOffset: max(0, visibleCharOffset))
        return reached.contains(visible) ? reached : visible
    }
    private var selectedPersona: PersonaRecord? { personas.first { $0.id == selectedPersonaId } }

    var body: some View {
        NavigationStack {
            PersonaChatBackdrop(appearance: chatAppearance, imagePath: chatBackgroundPath) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(session.bubbles) { bubble in
                                VStack(alignment: bubble.role == .user ? .trailing : .leading, spacing: 5) {
                                    if !bubble.reasoning.isEmpty { DisclosureGroup("思考过程") { Text(bubble.reasoning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
                                    if bubble.role == .user {
                                        PersonaChatBubbleSurface(role: .user, appearance: chatAppearance) {
                                            Text(bubble.content).textSelection(.enabled)
                                        }
                                    } else {
                                        CompanionBubbleContent(bubble: bubble, multiBubble: autonomy.multiBubbleReplies, appearance: chatAppearance)
                                        if autonomy.showTokenUsage { CompanionTokenUsageView(bubble: bubble) }
                                    }
                                    if let id = bubble.storedId { Text("#\(id)").font(.caption2).foregroundStyle(.tertiary) }
                                }
                                .frame(maxWidth: .infinity, alignment: bubble.role == .user ? .trailing : .leading)
                                .id(bubble.id)
                                .contextMenu {
                                    if bubble.storedId != nil {
                                        Button("编辑消息", systemImage: "pencil") {
                                            editingBubble = bubble
                                            editText = bubble.content
                                        }
                                        if bubble.role == .assistant {
                                            Button("重新生成", systemImage: "arrow.clockwise") { reroll(bubble) }
                                        }
                                        Button("从这里建立分支", systemImage: "arrow.triangle.branch") {
                                            Task { await session.branch(at: bubble, bookId: book.id) }
                                        }
                                        Button("删除消息", systemImage: "trash", role: .destructive) {
                                            Task { await session.delete(message: bubble) }
                                        }
                                    }
                                }
                            }
                        }.padding()
                    }
                    .onChange(of: session.bubbles.count) { _, _ in if let id = session.bubbles.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
                }
                Divider()
                if session.stoppedReply != nil {
                    HStack(spacing: 10) {
                        if session.isSavingStoppedReply {
                            ProgressView().controlSize(.small)
                            Text("正在保存停止前已生成的回复…").font(.caption)
                        } else {
                            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            Text("停止的回复残段仍保留，可重试保存或舍弃。")
                                .font(.caption)
                            Spacer()
                            Button("重试保存") { session.retrySavingStoppedReply() }
                                .buttonStyle(.borderless)
                            Button("舍弃", role: .destructive) { session.discardStoppedReply() }
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                if !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { value in
                                Button(value) { input = value; suggestions = [] }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }.padding(.horizontal).padding(.top, 8)
                    }
                }
                HStack(alignment: .bottom) {
                    Button { suggestReplies() } label: {
                        if suggesting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "wand.and.stars") }
                    }
                    .disabled(suggesting || session.isStreaming)
                    TextField("问问伴读…", text: $input, axis: .vertical).lineLimit(1...6).textFieldStyle(.roundedBorder)
                    if session.isStreaming {
                        Button { session.cancel() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    } else {
                        Menu {
                            Button("重试上一轮", systemImage: "arrow.clockwise") { retryLast() }
                                .disabled(!session.bubbles.contains(where: { $0.role == .user }) || session.stoppedReply != nil)
                        } label: { Image(systemName: "ellipsis.circle") }
                        Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.stoppedReply != nil)
                    }
                }.padding()
            }
            }
            .navigationTitle(selectedPersona.map { "伴读 · \($0.name)" } ?? "AI 伴读")
            .toolbar {
                if !embedded { ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        ForEach(personas) { persona in
                            Button {
                                selectedPersonaId = persona.id; suggestions = []
                                Task { await session.setPersona(persona.id) }
                            } label: {
                                Label(persona.name, systemImage: selectedPersonaId == persona.id ? "checkmark.circle.fill" : "person.circle")
                            }
                        }
                    } label: { Image(systemName: "person.crop.circle") }
                    Button { showSessions = true } label: { Image(systemName: "bubble.left.and.bubble.right") }
                }
            }
            .sheet(isPresented: $showSessions) { conversationSheet }
            .sheet(item: $editingBubble) { bubble in editSheet(bubble) }
            .task { await bootstrap(); applyInitialDraft(initialDraft) }
            .onChange(of: initialDraft) { _, value in applyInitialDraft(value) }
            .onChange(of: session.isStreaming) { oldValue, newValue in
                guard oldValue, !newValue, autonomy.suggestionRepliesEnabled, session.stoppedReply == nil else { return }
                // Only run after a completed, persisted assistant turn. Cancelled/failed partials
                // do not spend another model call.
                guard let last = session.bubbles.last, last.role == .assistant, last.storedId != nil,
                      !last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                suggestReplies(silent: true)
            }
            .onChange(of: selectedPersonaId) { _, _ in Task { await loadChatAppearance() } }
            .alert("请求失败", isPresented: Binding(get: { session.errorText != nil }, set: { if !$0 { session.errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(session.errorText ?? "") }
        }
    }

    private var conversationSheet: some View {
        NavigationStack {
            List {
                Button("新建会话") {
                    Task {
                        _ = try? await session.create(bookId: book.id, personaId: selectedPersonaId)
                        selectedPersonaId = session.personaId
                        showSessions = false
                    }
                }
                ForEach(session.conversations) { conversation in
                    Button {
                        Task {
                            try? await session.select(conversation.id)
                            selectedPersonaId = session.personaId
                            showSessions = false
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(conversation.title)
                                let personaName = personas.first { $0.id == conversation.personaId }?.name ?? "默认伴读"
                                Text("\(personaName) · \(Date(timeIntervalSince1970: Double(conversation.updatedAt) / 1000).formatted())")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); if conversation.id == session.conversationId { Image(systemName: "checkmark") }
                        }
                    }
                }
            }.navigationTitle("会话")
        }
    }

    @MainActor private func bootstrap() async {
        do {
            personas = try await PersonaRepository.shared.personas()
            let preferred = personas.first?.id
            await session.bootstrap(bookId: book.id, preferredPersonaId: preferred)
            selectedPersonaId = session.personaId ?? preferred
            await loadChatAppearance()
        } catch { session.errorText = error.localizedDescription }
    }

    @MainActor private func loadChatAppearance() async {
        let value = PersonaChatAppearance.decode(selectedPersona?.chatAppearanceJSON)
        chatAppearance = value
        if let id = value.backgroundImageId, let asset = try? await ImageAssetLibrary.shared.asset(id: id) {
            chatBackgroundPath = asset.filePath
        } else {
            chatBackgroundPath = nil
        }
    }


    @MainActor private func applyInitialDraft(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        // Do not overwrite something the user is already typing. Re-selecting text while the
        // companion pane is open still works once the composer is empty.
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input = String(clean.prefix(8_000))
            suggestions = []
        }
    }

    private func send() {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        input = ""
        suggestions = []
        Task { @MainActor in
            let context = await makeRunContext(query: query)
            session.send(userText: query, context: context)
        }
    }

    @MainActor
    private func makeRunContext(query: String) async -> AIChatRunContext {
        let persona = selectedPersona
        let effectiveMemory = (persona?.memoryEnabled ?? false) && memorySettings.settings.longTermEnabled
        let personaPrompt = await PersonaRepository.shared.systemPrompt(
            for: persona,
            triggerText: query,
            includeUserProfile: effectiveMemory
        )
        let voiceActive = autonomy.voiceRepliesEnabled && !(persona?.voiceId ?? "").isEmpty
        let imageActive = autonomy.imageRepliesEnabled
        let userMask = UserMaskStore.shared.settings.activeMask
        let toolset = CompanionToolset(
            bookId: book.id,
            scope: scope,
            personaId: selectedPersonaId,
            imageEnabled: imageActive,
            webEnabled: webSearch.configured(),
            memoryEnabled: effectiveMemory,
            crossBookMemorySearch: memorySettings.settings.crossBookChatSearch,
            maskId: userMask?.id ?? 0
        )
        let allowedTools = persona.map { Set($0.enabledTools) }
        let readOnlyBaseTools: Set<String> = [
            "search_book", "grep_book", "read_chapter", "list_annotations",
            "list_notes", "web_search", "web_scrape"
        ]
        let effectiveTools = allowedTools.map { allowed in
            toolset.specs.filter { readOnlyBaseTools.contains($0.name) || allowed.contains($0.name) }
        } ?? toolset.specs
        var shapeRules = ""
        if autonomy.multiBubbleReplies {
            shapeRules += "\n【消息形态】自然的短回复可以一行一个气泡；长分析、列表或代码请用 [整段] 与 [/整段] 包起来。"
        }
        if voiceActive {
            shapeRules += "\n若某一句特别适合用角色声音发出，可以在该行开头写 [语音]；最多 2 行。不要为了展示功能强行使用语音。"
        }
        if imageActive {
            shapeRules += "\n只有当插图确实有助于共读表达时才调用 generate_image；不要频繁生图，quote 必须逐字来自已读原文。"
        }
        let context = """
        \(personaPrompt)

        【共读范围】书名：《\(book.title)》。当前章节：\(chapter.title)。
        \(autonomy.spoilerProtectionEnabled ? "只能使用 ReadingScope 已读范围内的内容" : "用户已明确关闭防剧透，本轮允许读取整本书")；需要核对原文时优先调用工具，不要编造引用。当前可见位置：章节 \(chapter.chapterIndex)，UTF-16 偏移 \(visibleCharOffset)。
        当前页附近原文：
        \(String(scope.readableText(chapterIndex: chapter.chapterIndex, text: chapterText).suffix(8_000)))
        \(shapeRules)
        """
        return AIChatRunContext(
            bookId: book.id,
            personaId: selectedPersonaId,
            memoryEnabled: effectiveMemory,
            systemContext: context,
            scope: scope,
            tools: effectiveTools,
            toolExecutor: { call, conversationId in
                if let allowedTools, !readOnlyBaseTools.contains(call.name), !allowedTools.contains(call.name) {
                    return "{\"ok\":false,\"error_code\":\"CAPABILITY_DISABLED\"}"
                }
                return try await toolset.execute(call, sourceConversationId: conversationId)
            },
            voiceRepliesEnabled: voiceActive,
            voiceId: persona?.voiceId ?? "",
            voiceEmotion: persona?.voiceEmotion,
            userMask: userMask,
            chatModelId: persona?.chatModelId
        )
    }

    private func reroll(_ bubble: CompanionBubble) {
        guard let query = precedingUserText(for: bubble) else { return }
        suggestions = []
        Task { @MainActor in
            let context = await makeRunContext(query: query)
            await session.reroll(message: bubble, context: context)
        }
    }

    private func retryLast() {
        guard let query = session.bubbles.last(where: { $0.role == .user })?.content else { return }
        suggestions = []
        Task { @MainActor in
            let context = await makeRunContext(query: query)
            await session.retry(context: context)
        }
    }

    private func precedingUserText(for bubble: CompanionBubble) -> String? {
        guard let index = session.bubbles.firstIndex(where: { $0.id == bubble.id }) else { return nil }
        return session.bubbles[..<index].last(where: { $0.role == .user })?.content
    }

    @ViewBuilder
    private func editSheet(_ bubble: CompanionBubble) -> some View {
        NavigationStack {
            Form {
                Section(bubble.role == .user ? "编辑用户消息" : "编辑 AI 回复") {
                    TextEditor(text: $editText)
                        .frame(minHeight: 180)
                }
                if bubble.role == .user {
                    Section {
                        Text("保存后会删除这条用户消息之后的旧回复与工具结果，清空该会话的滚动摘要/长期记忆水位，并按当前阅读范围重新生成。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("编辑消息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editingBubble = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveEdit(bubble) }
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveEdit(_ bubble: CompanionBubble) {
        let clean = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        editingBubble = nil
        suggestions = []
        Task { @MainActor in
            let context = bubble.role == .user ? await makeRunContext(query: clean) : nil
            await session.edit(message: bubble, newContent: clean, context: context)
        }
    }

    private func suggestReplies(silent: Bool = false) {
        guard !suggesting, !session.isStreaming else { return }
        guard let last = session.bubbles.last, last.role == .assistant,
              !last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        suggesting = true
        Task { @MainActor in
            do {
                let visible = scope.readableText(chapterIndex: chapter.chapterIndex, text: chapterText)
                suggestions = try await ReplySuggestionService.shared.suggest(
                    book: book, chapter: chapter, visibleText: visible,
                    conversationId: session.conversationId, persona: selectedPersona)
            } catch {
                if !silent { session.errorText = error.localizedDescription }
            }
            suggesting = false
        }
    }
}

private struct CompanionTokenUsageView: View {
    let bubble: CompanionBubble
    var body: some View {
        if let input = bubble.inputTokens, let output = bubble.outputTokens, input > 0 || output > 0 {
            let ms = max(1, bubble.generationTimeMs ?? 0)
            let speed = Double(output) / (Double(ms) / 1000.0)
            Text("输入 \(input) · 输出 \(output) · 共 \(input + output) token · \(String(format: "%.1f", Double(ms) / 1000))s · \(String(format: "%.1f", speed)) tok/s")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

private struct CompanionBubbleContent: View {
    let bubble: CompanionBubble
    let multiBubble: Bool
    let appearance: PersonaChatAppearance
    @State private var player: AVAudioPlayer?

    private var parts: [CompanionMessagePart] {
        let parsed = CompanionMessageParser.parse(bubble.content, multiBubble: multiBubble)
        return parsed.isEmpty && bubble.isStreaming ? [.text("…")] : parsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let text):
                    PersonaChatBubbleSurface(role: .assistant, appearance: appearance) {
                        Text(text).textSelection(.enabled)
                    }
                case .voice(let text):
                    PersonaChatBubbleSurface(role: .assistant, appearance: appearance) {
                        HStack(spacing: 10) {
                            Button { playVoice(text) } label: { Image(systemName: "waveform.circle.fill").font(.title2) }
                            Text(text).textSelection(.enabled)
                        }
                    }
                }
            }
            ForEach(bubble.attachments.filter { $0.kind == .image }) { attachment in
                if let image = UIImage(contentsOfFile: attachment.path) {
                    VStack(alignment: .leading, spacing: 5) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 14))
                        if !attachment.title.isEmpty { Text(attachment.title).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func playVoice(_ text: String) {
        guard let attachment = bubble.attachments.first(where: { $0.kind == .audio && ($0.text == text || $0.title == text) }),
              FileManager.default.fileExists(atPath: attachment.path) else { return }
        do { let value = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: attachment.path)); player = value; value.play() } catch { }
    }
}
