import Foundation

extension Notification.Name {
    static let proactiveAnnotationPolicyChanged = Notification.Name("MoRead.ProactiveAnnotationPolicyChanged")
    static let proactiveAnnotationsDidChange = Notification.Name("MoRead.ProactiveAnnotationsDidChange")
}

struct ProactiveAnnotationBatchNotice: Sendable {
    var bookId: Int64
    var chapterIndex: Int
    var personaId: Int64
    var personaName: String
    var createdIds: [Int64]
    var dailyBudgetExhausted: Bool
}

actor ProactiveAnnotationScheduler {
    static let shared = ProactiveAnnotationScheduler()

    private struct Trigger: Hashable, Sendable {
        var bookId: Int64
        var chapterIndex: Int
        var timing: ProactiveAnnotationTiming
    }

    private var readerBookId: Int64?
    private var pending: [Trigger] = []
    private var active: Trigger?
    private var worker: Task<Void, Never>?
    private var readerVersion: UInt64 = 0
    private var exhaustedNoticeDate: Date?
    private var exhaustedNoticeBooks: Set<Int64> = []

    func setReaderBook(_ bookId: Int64?) {
        guard readerBookId != bookId else { return }
        readerBookId = bookId
        readerVersion &+= 1
        pending.removeAll()
        active = nil
        worker?.cancel()
        worker = nil
    }

    func clearReaderBook(_ bookId: Int64) {
        if readerBookId == bookId { setReaderBook(nil) }
    }

    func policyChanged(bookId: Int64, chapterIndex: Int) async {
        guard readerBookId == bookId else { return }
        pending.removeAll()
        worker?.cancel(); worker = nil; active = nil
        let policy = await MainActor.run { ProactiveAnnotationSettingsStore.shared.policy(for: bookId) }
        guard policy.enabled else { return }
        await enqueue(.init(bookId: bookId, chapterIndex: chapterIndex, timing: policy.limits.timing))
    }

    func onChapterEntered(bookId: Int64, chapterIndex: Int) async {
        await enqueue(.init(bookId: bookId, chapterIndex: chapterIndex, timing: .onChapterEntry))
    }

    func onChapterCompleted(bookId: Int64, chapterIndex: Int) async {
        await enqueue(.init(bookId: bookId, chapterIndex: chapterIndex, timing: .afterChapterComplete))
    }

    private func enqueue(_ trigger: Trigger) async {
        guard readerBookId == trigger.bookId else { return }
        let policy = await MainActor.run { ProactiveAnnotationSettingsStore.shared.policy(for: trigger.bookId) }
        guard policy.enabled, policy.limits.timing == trigger.timing else { return }
        let last = max(trigger.chapterIndex, (try? await LibraryRepository.shared.book(id: trigger.bookId)?.totalChapters ?? 0) ?? 0) - 1
        let ahead = trigger.timing == .onChapterEntry ? policy.limits.aheadChapters : 0
        let upper = min(max(trigger.chapterIndex, last), trigger.chapterIndex + max(0, min(5, ahead)))
        guard upper >= trigger.chapterIndex else { return }
        for index in trigger.chapterIndex...upper {
            let next = Trigger(bookId: trigger.bookId, chapterIndex: index, timing: trigger.timing)
            if next != active, !pending.contains(next), pending.count < 6 { pending.append(next) }
        }
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        let version = readerVersion
        worker = Task { [weak self] in await self?.drain(expectedReaderVersion: version) }
    }

    private func drain(expectedReaderVersion: UInt64) async {
        defer { worker = nil; active = nil }
        while !Task.isCancelled, expectedReaderVersion == readerVersion, let trigger = pending.first {
            pending.removeFirst()
            active = trigger
            do { try await run(trigger, expectedReaderVersion: expectedReaderVersion) }
            catch is CancellationError { if Task.isCancelled { return } }
            catch { /* A failed chapter remains resumable in its durable job ledger. */ }
            active = nil
        }
    }

    private func run(_ trigger: Trigger, expectedReaderVersion: UInt64) async throws {
        guard readerBookId == trigger.bookId, expectedReaderVersion == readerVersion else { return }
        let policy = await MainActor.run { ProactiveAnnotationSettingsStore.shared.policy(for: trigger.bookId) }
        guard policy.enabled, policy.limits.timing == trigger.timing else { return }

        let people = try await PersonaRepository.shared.personas()
        let requested = policy.personaIds.isEmpty ? Array(people.prefix(1).map(\.id)) : policy.personaIds
        let personas = requested.compactMap { id in people.first { $0.id == id } }
        guard !personas.isEmpty else { return }

        for (position, persona) in personas.enumerated() {
            try Task.checkCancellation()
            guard readerBookId == trigger.bookId, expectedReaderVersion == readerVersion else { return }
            let remainingPersonas = max(1, personas.count - position)
            var limits = policy.limits
            if limits.dailyMax != ProactiveAnnotationLimits.unlimited {
                let remaining = try await remainingDaily(limits: limits)
                if remaining <= 0 {
                    await postNotice(.init(bookId: trigger.bookId, chapterIndex: trigger.chapterIndex, personaId: persona.id, personaName: persona.name, createdIds: [], dailyBudgetExhausted: true), persona: persona, policy: policy)
                    return
                }
                let fairShare = (remaining + remainingPersonas - 1) / remainingPersonas
                if limits.maxPerChapter == ProactiveAnnotationLimits.unlimited { limits.maxPerChapter = fairShare }
                else { limits.maxPerChapter = min(limits.maxPerChapter, fairShare) }
            }

            let prompt = await PersonaRepository.shared.systemPrompt(for: persona, triggerText: "")
            let result = try await ProactiveAnnotationService.shared.generate(
                bookId: trigger.bookId,
                chapterIndex: trigger.chapterIndex,
                personaId: persona.id,
                personaName: persona.name,
                personaPrompt: prompt,
                limits: limits,
                // Entry-time pre-generation is an explicit user option. It may prepare the
                // configured current+ahead chapters, while sourceScope keeps future rows hidden
                // until the reader reaches them.
                allowUnreadSource: trigger.timing == .onChapterEntry,
                voiceEnabled: policy.voiceEnabled,
                imagesEnabled: policy.imagesEnabled,
                personaVoiceId: persona.voiceId,
                personaVoiceEmotion: persona.voiceEmotion
            )
            if !result.createdIds.isEmpty || result.dailyBudgetExhausted {
                await postNotice(.init(bookId: trigger.bookId, chapterIndex: trigger.chapterIndex, personaId: persona.id, personaName: persona.name, createdIds: result.createdIds, dailyBudgetExhausted: result.dailyBudgetExhausted), persona: persona, policy: policy)
            }
        }
    }

    private func remainingDaily(limits: ProactiveAnnotationLimits) async throws -> Int {
        guard limits.dailyMax != ProactiveAnnotationLimits.unlimited else { return Int.max }
        let start = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        let used = try await MoReadDatabase.shared.scalarInt(
            "SELECT COUNT(*) FROM annotations WHERE proactiveJobId IS NOT NULL AND createdAt>=?",
            [.integer(start)]
        ) ?? 0
        return max(0, limits.dailyMax - Int(used))
    }

    private func postNotice(_ notice: ProactiveAnnotationBatchNotice, persona: PersonaRecord, policy: ProactiveAnnotationPolicy) async {
        var message: String?
        if notice.dailyBudgetExhausted {
            let today = Calendar.current.startOfDay(for: Date())
            if exhaustedNoticeDate != today { exhaustedNoticeDate = today; exhaustedNoticeBooks.removeAll() }
            guard exhaustedNoticeBooks.insert(notice.bookId).inserted else { return }
            guard policy.noticeMode != .off else { return }
            message = ProactiveAnnotationNoticeComposer.dailyBudgetNotice(dailyMax: policy.limits.dailyMax)
        } else {
            message = await ProactiveAnnotationNoticeComposer.compose(
                persona: persona,
                count: notice.createdIds.count,
                mode: policy.noticeMode,
                seed: Int(truncatingIfNeeded: notice.bookId) &+ notice.chapterIndex
            )
        }
        guard let message else { return }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .proactiveAnnotationsDidChange,
                object: nil,
                userInfo: [
                    "bookId": notice.bookId,
                    "chapterIndex": notice.chapterIndex,
                    "personaId": notice.personaId,
                    "personaName": notice.personaName,
                    "createdIds": notice.createdIds,
                    "createdCount": notice.createdIds.count,
                    "dailyBudgetExhausted": notice.dailyBudgetExhausted,
                    "message": message,
                    "showNotice": true
                ]
            )
        }
    }
}
