import Foundation

struct CompanionBubble: Identifiable, Equatable {
    var id: UUID = UUID()
    var storedId: Int64?
    var role: ChatRole
    var content: String
    var reasoning: String = ""
    var isStreaming = false
    var sourceScope: ReadingScope?
    var attachments: [CompanionAttachment] = []
    var inputTokens: Int64?
    var outputTokens: Int64?
    var generationTimeMs: Int64?
}

struct AIChatRunContext {
    let bookId: Int64
    let personaId: Int64?
    let memoryEnabled: Bool
    let systemContext: String
    let scope: ReadingScope
    let tools: [ToolSpec]
    let toolExecutor: (@Sendable (ToolCall, Int64) async throws -> String)?
    let voiceRepliesEnabled: Bool
    let voiceId: String
    let voiceEmotion: String?
    let userMask: UserMask?
    let chatModelId: Int64?
}

struct StoppedAIReply: Identifiable {
    let id = UUID()
    let conversationId: Int64
    let roundId: String
    let bubbleId: UUID
    let content: String
    let reasoning: String
    let attachments: [CompanionAttachment]
    let scope: ReadingScope
    let maskId: Int64
    let inputTokens: Int64?
    let outputTokens: Int64?
    let generationTimeMs: Int64?
}

@MainActor
final class AIChatSession: ObservableObject {
    @Published var conversations: [AIConversationRecord] = []
    @Published var conversationId: Int64?
    @Published var personaId: Int64?
    @Published var bubbles: [CompanionBubble] = []
    @Published var isStreaming = false
    @Published var errorText: String?
    @Published var stoppedReply: StoppedAIReply?
    @Published var isSavingStoppedReply = false

    private var streamTask: Task<Void, Never>?
    private var currentRoundId: String?
    private var currentStartedAt: Date?
    private var lastRunContext: AIChatRunContext?
    private let repo = AIConversationRepository.shared

    func bootstrap(bookId: Int64, preferredPersonaId: Int64? = nil) async {
        do {
            conversations = try await repo.conversations(bookId: bookId)
            if let preferredPersonaId, let matching = conversations.first(where: { $0.personaId == preferredPersonaId }) {
                try await select(matching.id)
            } else if let first = conversations.first {
                try await select(first.id)
            } else {
                _ = try await create(bookId: bookId, personaId: preferredPersonaId)
            }
        } catch { errorText = error.localizedDescription }
    }

    @discardableResult
    func create(bookId: Int64, personaId: Int64? = nil, title: String = "新会话") async throws -> Int64 {
        let id = try await repo.create(bookId: bookId, personaId: personaId, title: title)
        conversations = try await repo.conversations(bookId: bookId)
        try await select(id)
        return id
    }

    func select(_ id: Int64) async throws {
        guard !isStreaming else { return }
        guard let conversation = try await repo.conversation(id: id) else { throw AIClientError.malformed("会话不存在") }
        conversationId = id
        personaId = conversation.personaId
        let stored = try await repo.messages(conversationId: id)
        bubbles = stored.filter { ["user", "assistant"].contains($0.role) }.map(Self.bubble)
        stoppedReply = nil
        isSavingStoppedReply = false
    }

    func send(
        userText: String,
        bookId: Int64,
        personaId requestedPersonaId: Int64?,
        memoryEnabled: Bool,
        systemContext: String,
        scope: ReadingScope,
        tools: [ToolSpec] = [],
        toolExecutor: (@Sendable (ToolCall, Int64) async throws -> String)? = nil,
        voiceRepliesEnabled: Bool = false,
        voiceId: String = "",
        voiceEmotion: String? = nil,
        userMask: UserMask? = nil,
        chatModelId: Int64? = nil
    ) {
        send(
            userText: userText,
            context: .init(
                bookId: bookId,
                personaId: requestedPersonaId,
                memoryEnabled: memoryEnabled,
                systemContext: systemContext,
                scope: scope,
                tools: tools,
                toolExecutor: toolExecutor,
                voiceRepliesEnabled: voiceRepliesEnabled,
                voiceId: voiceId,
                voiceEmotion: voiceEmotion,
                userMask: userMask,
                chatModelId: chatModelId
            )
        )
    }

    func send(userText: String, context: AIChatRunContext) {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, stoppedReply == nil else { return }
        startGeneration(userText: text, existingUser: nil, context: context)
    }

    func edit(message: CompanionBubble, newContent: String, context: AIChatRunContext? = nil) async {
        guard !isStreaming, stoppedReply == nil, let id = message.storedId else { return }
        do {
            let result = try await repo.editForRegeneration(messageId: id, content: newContent)
            try await select(result.conversationId)
            if result.shouldRegenerate, let user = result.user {
                guard let context else { throw AIClientError.malformed("缺少重新生成上下文") }
                startGeneration(userText: user.content, existingUser: user, context: context)
            }
        } catch { errorText = error.localizedDescription }
    }

    func delete(message: CompanionBubble) async {
        guard !isStreaming, stoppedReply == nil, let id = message.storedId else { return }
        do {
            try await repo.deleteVisibleMessage(messageId: id)
            if let cid = conversationId { try await select(cid) }
        } catch { errorText = error.localizedDescription }
    }

    func reroll(message: CompanionBubble, context: AIChatRunContext) async {
        guard !isStreaming, stoppedReply == nil, let id = message.storedId else { return }
        do {
            let user = try await repo.prepareReroll(assistantMessageId: id)
            try await select(user.conversationId)
            startGeneration(userText: user.content, existingUser: user, context: context)
        } catch { errorText = error.localizedDescription }
    }

    func retry(context: AIChatRunContext) async {
        guard !isStreaming, stoppedReply == nil, let cid = conversationId else { return }
        do {
            let user = try await repo.prepareRetry(conversationId: cid)
            try await select(cid)
            startGeneration(userText: user.content, existingUser: user, context: context)
        } catch { errorText = error.localizedDescription }
    }

    func setPersona(_ id: Int64?) async {
        guard !isStreaming, stoppedReply == nil else { return }
        personaId = id
        guard let conversationId else { return }
        do { try await repo.updateConversationPersona(conversationId: conversationId, personaId: id) }
        catch { errorText = error.localizedDescription }
    }

    /// Stop generation but keep text that already arrived. The partial is persisted after the
    /// generation task has fully unwound so a late normal commit cannot create a duplicate row.
    func cancel() {
        guard isStreaming else { return }
        let task = streamTask
        let roundId = currentRoundId
        let started = currentStartedAt
        let context = lastRunContext
        let cid = conversationId
        let partialIndex = bubbles.lastIndex(where: { $0.role == .assistant && $0.isStreaming })

        task?.cancel()
        streamTask = nil
        isStreaming = false
        if let partialIndex { bubbles[partialIndex].isStreaming = false }

        guard let partialIndex, bubbles.indices.contains(partialIndex),
              let cid, let roundId, let context else { return }
        let bubble = bubbles[partialIndex]
        let hasPartial = !bubble.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !bubble.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasPartial else { return }

        let stopped = StoppedAIReply(
            conversationId: cid,
            roundId: roundId,
            bubbleId: bubble.id,
            content: bubble.content,
            reasoning: bubble.reasoning,
            attachments: bubble.attachments,
            scope: context.scope,
            maskId: context.userMask?.id ?? 0,
            inputTokens: bubble.inputTokens,
            outputTokens: bubble.outputTokens,
            generationTimeMs: started.map { Int64(Date().timeIntervalSince($0) * 1000) }
        )
        stoppedReply = stopped
        Task { @MainActor in
            _ = await task?.value
            await saveStoppedReply()
        }
    }

    func retrySavingStoppedReply() {
        guard stoppedReply != nil, !isSavingStoppedReply else { return }
        Task { @MainActor in await saveStoppedReply() }
    }

    func discardStoppedReply() {
        guard !isSavingStoppedReply else { return }
        if let id = stoppedReply?.bubbleId,
           let index = bubbles.firstIndex(where: { $0.id == id && $0.storedId == nil }) {
            bubbles.remove(at: index)
        }
        stoppedReply = nil
        errorText = nil
    }

    func branch(at message: CompanionBubble, bookId: Int64) async {
        guard !isStreaming, stoppedReply == nil,
              let sid = message.storedId, let cid = conversationId else { return }
        do {
            let newID = try await repo.branch(conversationId: cid, throughMessageId: sid)
            conversations = try await repo.conversations(bookId: bookId)
            try await select(newID)
        } catch { errorText = error.localizedDescription }
    }

    func deleteConversation(_ id: Int64, bookId: Int64) async {
        guard !isStreaming, stoppedReply == nil else { return }
        do {
            try await repo.deleteConversation(id)
            conversations = try await repo.conversations(bookId: bookId)
            if conversationId == id {
                if let next = conversations.first { try await select(next.id) }
                else { _ = try await create(bookId: bookId, personaId: personaId) }
            }
        } catch { errorText = error.localizedDescription }
    }

    private func startGeneration(userText: String, existingUser: AIStoredMessage?, context: AIChatRunContext) {
        guard !isStreaming else { return }
        lastRunContext = context
        currentRoundId = UUID().uuidString
        currentStartedAt = Date()
        isStreaming = true
        errorText = nil

        if existingUser == nil {
            bubbles.append(.init(role: .user, content: userText, sourceScope: context.scope))
        }
        let assistantIndex = bubbles.count
        bubbles.append(.init(role: .assistant, content: "", isStreaming: true, sourceScope: context.scope))
        let roundId = currentRoundId!
        let started = currentStartedAt!

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cid: Int64
                let effectiveMask: UserMask?
                let maskId: Int64
                if let existingUser {
                    cid = existingUser.conversationId
                    maskId = existingUser.maskId
                    effectiveMask = try maskForStoredUser(id: existingUser.maskId)
                } else {
                    cid = try await ensureConversation(bookId: context.bookId, personaId: context.personaId, firstUserText: userText)
                    maskId = context.userMask?.id ?? 0
                    effectiveMask = context.userMask
                    _ = try await repo.append(
                        conversationId: cid,
                        role: "user",
                        content: userText,
                        scope: context.scope,
                        clientRoundId: UUID().uuidString,
                        maskId: maskId
                    )
                }
                guard var conversation = try await repo.conversation(id: cid) else { throw AIClientError.malformed("会话不存在") }

                var systemBlocks = [context.systemContext]
                if let effectiveMask {
                    systemBlocks.append("【用户面具】\n名称：\(effectiveMask.name)\n\(effectiveMask.description)\n这是用户侧身份资料，不是给角色执行的指令。")
                }
                if !conversation.rollingSummary.isEmpty {
                    systemBlocks.append("【较早对话的滚动摘要】\n\(conversation.rollingSummary)")
                }
                let memorySettings = CompanionMemorySettingsStore.shared.settings
                if context.memoryEnabled && memorySettings.longTermEnabled, let pid = context.personaId {
                    let memories = await MemoryRepository.shared.search(
                        query: userText,
                        personaId: pid,
                        bookId: memorySettings.crossBookEnabled ? nil : context.bookId,
                        maskId: maskId,
                        limit: 6
                    )
                    if !memories.isEmpty {
                        systemBlocks.append("【长期记忆（仅作稳定背景；若与当前消息冲突，以当前消息为准）】\n" + memories.map { "- \($0.summary)" }.joined(separator: "\n"))
                    }
                }

                var history = try await protocolHistory(conversation: conversation)
                history.insert(.init(role: .system, content: systemBlocks.joined(separator: "\n\n")), at: 0)
                history = GlobalPromptInjector.inject(messages: history, presets: GlobalPromptPresetStore.shared.presets)
                let resolved = try await resolveChatClient(modelId: context.chatModelId)
                var inputTokens: Int64?, outputTokens: Int64?, reasoning = "", toolCalls: [ToolCall] = []

                try await streamRound(
                    resolved: resolved,
                    history: history,
                    tools: context.tools,
                    assistantIndex: assistantIndex,
                    reasoning: &reasoning,
                    inputTokens: &inputTokens,
                    outputTokens: &outputTokens,
                    toolCalls: &toolCalls
                )
                var rounds = 0
                while !toolCalls.isEmpty, let toolExecutor = context.toolExecutor, rounds < 8 {
                    rounds += 1
                    history.append(.init(role: .assistant, content: bubbles[assistantIndex].content, toolCalls: toolCalls))
                    for call in toolCalls {
                        let result = try await toolExecutor(call, cid)
                        if let attachment = Self.attachmentFromToolResult(result),
                           !bubbles[assistantIndex].attachments.contains(where: { $0.path == attachment.path }) {
                            bubbles[assistantIndex].attachments.append(attachment)
                        }
                        history.append(.init(role: .tool, content: result, toolCallId: call.id))
                    }
                    toolCalls = []
                    try await streamRound(
                        resolved: resolved,
                        history: history,
                        tools: context.tools,
                        assistantIndex: assistantIndex,
                        reasoning: &reasoning,
                        inputTokens: &inputTokens,
                        outputTokens: &outputTokens,
                        toolCalls: &toolCalls
                    )
                }

                if context.voiceRepliesEnabled, !context.voiceId.isEmpty {
                    let voiceParts = CompanionMessageParser.parse(bubbles[assistantIndex].content, multiBubble: true).compactMap { part -> String? in
                        if case .voice(let text) = part { return text }
                        return nil
                    }.prefix(CompanionMessageParser.maxVoiceParts)
                    for spoken in voiceParts {
                        do {
                            let url = try await CloudSpeechService.shared.cachedSpeech(
                                text: spoken,
                                voice: context.voiceId,
                                emotion: context.voiceEmotion,
                                bookId: context.bookId
                            )
                            let attachment = CompanionAttachment(kind: .audio, path: url.path, title: "语音回复", text: spoken)
                            if !bubbles[assistantIndex].attachments.contains(where: { $0.path == attachment.path }) {
                                bubbles[assistantIndex].attachments.append(attachment)
                            }
                        } catch { /* Autonomous media failure must not discard the text reply. */ }
                    }
                }

                let generation = Int64(Date().timeIntervalSince(started) * 1000)
                let attachmentsJSON = bubbles[assistantIndex].attachments.isEmpty
                    ? nil
                    : String(data: try JSONEncoder().encode(bubbles[assistantIndex].attachments), encoding: .utf8)
                let stored = try await repo.append(
                    conversationId: cid,
                    role: "assistant",
                    content: bubbles[assistantIndex].content,
                    reasoning: reasoning.isEmpty ? nil : reasoning,
                    toolCallsJSON: toolCalls.isEmpty ? nil : String(data: try JSONEncoder().encode(toolCalls), encoding: .utf8),
                    attachmentsJSON: attachmentsJSON,
                    scope: context.scope,
                    clientRoundId: roundId,
                    maskId: maskId,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    generationTimeMs: generation
                )
                bubbles[assistantIndex].storedId = stored
                bubbles[assistantIndex].isStreaming = false
                bubbles[assistantIndex].reasoning = reasoning
                bubbles[assistantIndex].inputTokens = inputTokens
                bubbles[assistantIndex].outputTokens = outputTokens
                bubbles[assistantIndex].generationTimeMs = generation
                conversations = try await repo.conversations(bookId: context.bookId)

                if context.memoryEnabled && CompanionMemorySettingsStore.shared.settings.longTermEnabled,
                   let pid = context.personaId {
                    conversation = try await repo.conversation(id: cid) ?? conversation
                    try? await MemoryConsolidationService.shared.updateRollingSummary(conversation: conversation)
                    conversation = try await repo.conversation(id: cid) ?? conversation
                    try? await MemoryConsolidationService.shared.consolidate(
                        conversation: conversation,
                        personaId: pid,
                        maskId: maskId,
                        bookId: context.bookId
                    )
                }
                stoppedReply = nil
            } catch is CancellationError {
                if bubbles.indices.contains(assistantIndex) { bubbles[assistantIndex].isStreaming = false }
            } catch {
                if bubbles.indices.contains(assistantIndex) {
                    bubbles[assistantIndex].isStreaming = false
                    // Preserve a failed partial so the user can keep what already arrived.
                    if bubbles[assistantIndex].storedId == nil,
                       let cid = conversationId,
                       !bubbles[assistantIndex].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        stoppedReply = StoppedAIReply(
                            conversationId: cid,
                            roundId: roundId,
                            bubbleId: bubbles[assistantIndex].id,
                            content: bubbles[assistantIndex].content,
                            reasoning: bubbles[assistantIndex].reasoning,
                            attachments: bubbles[assistantIndex].attachments,
                            scope: context.scope,
                            maskId: existingUser?.maskId ?? context.userMask?.id ?? 0,
                            inputTokens: bubbles[assistantIndex].inputTokens,
                            outputTokens: bubbles[assistantIndex].outputTokens,
                            generationTimeMs: Int64(Date().timeIntervalSince(started) * 1000)
                        )
                    }
                }
                errorText = error.localizedDescription
            }
            isStreaming = false
            if currentRoundId == roundId {
                currentRoundId = nil
                currentStartedAt = nil
                streamTask = nil
            }
        }
    }

    private func saveStoppedReply() async {
        guard let stopped = stoppedReply, !isSavingStoppedReply else { return }
        isSavingStoppedReply = true
        defer { isSavingStoppedReply = false }
        do {
            let existing = try await repo.message(conversationId: stopped.conversationId, clientRoundId: stopped.roundId)
            let storedId: Int64
            if let existing {
                storedId = existing.id
            } else {
                let attachmentsJSON = stopped.attachments.isEmpty
                    ? nil
                    : String(data: try JSONEncoder().encode(stopped.attachments), encoding: .utf8)
                storedId = try await repo.append(
                    conversationId: stopped.conversationId,
                    role: "assistant",
                    content: stopped.content,
                    reasoning: stopped.reasoning.isEmpty ? nil : stopped.reasoning,
                    attachmentsJSON: attachmentsJSON,
                    scope: stopped.scope,
                    clientRoundId: stopped.roundId,
                    maskId: stopped.maskId,
                    inputTokens: stopped.inputTokens,
                    outputTokens: stopped.outputTokens,
                    generationTimeMs: stopped.generationTimeMs
                )
            }
            if let index = bubbles.firstIndex(where: { $0.id == stopped.bubbleId }) {
                bubbles[index].storedId = storedId
                bubbles[index].isStreaming = false
            }
            stoppedReply = nil
            errorText = nil
        } catch {
            errorText = "停止的回复未能保存；残段仍保留，可重试保存或明确舍弃。\(error.localizedDescription)"
        }
    }

    private func maskForStoredUser(id: Int64) throws -> UserMask? {
        guard id != 0 else { return nil }
        guard let mask = UserMaskStore.shared.settings.masks.first(where: { $0.id == id }) else {
            throw AIClientError.malformed("这条消息使用的用户面具已删除，请新建会话后继续")
        }
        return mask
    }

    private func ensureConversation(bookId: Int64, personaId requestedPersonaId: Int64?, firstUserText: String) async throws -> Int64 {
        if let id = conversationId,
           let current = try await repo.conversation(id: id),
           current.personaId == requestedPersonaId {
            return id
        }
        let title = String(firstUserText.prefix(24))
        return try await create(bookId: bookId, personaId: requestedPersonaId, title: title)
    }

    private func resolveChatClient(modelId: Int64?) async throws -> ResolvedChatClient {
        if let modelId,
           let model = try await AIProviderRepository.shared.model(id: modelId),
           model.type == .chat,
           let provider = try await AIProviderRepository.shared.provider(id: model.providerId) {
            return try AIClientFactory.forModel(provider: provider, model: model)
        }
        return try await AIClientFactory.forRole(.chat)
    }

    private func protocolHistory(conversation: AIConversationRecord) async throws -> [AIChatMessage] {
        let all = try await repo.messages(conversationId: conversation.id)
            .filter { $0.id > conversation.memoryConsolidatedThroughMessageId }
        let recent = Array(all.suffix(24))
        return recent.map { message in
            .init(
                role: ChatRole(rawValue: message.role) ?? .assistant,
                content: message.content,
                toolCalls: decodeTools(message.toolCallsJSON),
                toolCallId: message.toolCallId
            )
        }
    }

    private func streamRound(
        resolved: ResolvedChatClient,
        history: [AIChatMessage],
        tools: [ToolSpec],
        assistantIndex: Int,
        reasoning: inout String,
        inputTokens: inout Int64?,
        outputTokens: inout Int64?,
        toolCalls: inout [ToolCall]
    ) async throws {
        for try await delta in resolved.client.chatStream(messages: history, tools: tools, options: resolved.options) {
            if Task.isCancelled { throw CancellationError() }
            switch delta {
            case .text(let chunk): bubbles[assistantIndex].content += chunk
            case .reasoning(let chunk):
                reasoning += chunk
                bubbles[assistantIndex].reasoning = reasoning
            case .usage(let i, let o, _):
                inputTokens = (inputTokens ?? 0) + (i ?? 0)
                outputTokens = (outputTokens ?? 0) + (o ?? 0)
                bubbles[assistantIndex].inputTokens = inputTokens
                bubbles[assistantIndex].outputTokens = outputTokens
            case .toolCalls(let calls): toolCalls = calls
            }
        }
    }

    private static func bubble(_ stored: AIStoredMessage) -> CompanionBubble {
        .init(
            storedId: stored.id,
            role: ChatRole(rawValue: stored.role) ?? .assistant,
            content: stored.content,
            reasoning: stored.reasoningContent ?? "",
            sourceScope: stored.sourceScopeChapterIndex >= 0
                ? .upto(chapterIndex: stored.sourceScopeChapterIndex, charOffset: max(0, stored.sourceScopeCharOffset))
                : nil,
            attachments: decodeAttachments(stored.attachmentsJSON),
            inputTokens: stored.inputTokens,
            outputTokens: stored.outputTokens,
            generationTimeMs: stored.generationTimeMs
        )
    }

    private static func decodeAttachments(_ raw: String?) -> [CompanionAttachment] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CompanionAttachment].self, from: data)) ?? []
    }

    private static func attachmentFromToolResult(_ raw: String) -> CompanionAttachment? {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = root["_attachment"] as? [String: Any],
              let kindRaw = item["kind"] as? String,
              let kind = CompanionAttachment.Kind(rawValue: kindRaw),
              let path = item["path"] as? String,
              !path.isEmpty else { return nil }
        return .init(
            kind: kind,
            path: path,
            title: item["title"] as? String ?? "",
            text: item["text"] as? String ?? ""
        )
    }

    private func decodeTools(_ raw: String?) -> [ToolCall] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ToolCall].self, from: data)) ?? []
    }
}
