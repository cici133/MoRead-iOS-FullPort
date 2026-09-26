import Foundation

@MainActor
final class ContinuousListenSession: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var chapterIndex = 0
    @Published private(set) var sentenceIndex = 0
    @Published private(set) var currentRange: NSRange?
    @Published var sleepTimer: SleepTimerState?

    let tts: TTSManager
    var onChapterChanged: ((Int, Int) -> Void)?
    var onPositionChanged: ((Int, Int) -> Void)?
    var onStopped: (() -> Void)?

    private var book: Book?
    private var chapters: [Chapter] = []
    private var body = ""
    private var spans: [SentenceSpan] = []
    private var lastTick = Date()
    private var timer: Timer?

    init(tts: TTSManager) {
        self.tts = tts
        tts.onFinished = { [weak self] in self?.advanceAfterSpeech() }
    }

    convenience init() {
        self.init(tts: TTSManager())
    }

    func start(book: Book, chapters: [Chapter], chapterIndex: Int, charOffset: Int) async {
        self.book = book
        self.chapters = chapters
        self.chapterIndex = max(0, min(chapterIndex, max(0, chapters.count - 1)))
        isActive = true
        await loadChapter(offset: charOffset)
        installRemoteCommands()
        startTimer()
        speakCurrent()
    }

    func stop() {
        tts.stop(); isActive = false; timer?.invalidate(); timer = nil
        MediaRemoteController.shared.clear(); onStopped?()
    }

    func toggle() {
        if tts.isSpeaking { tts.pause() }
        else if isActive { tts.resume(); if !tts.isSpeaking { speakCurrent() } }
        updateNowPlaying()
    }

    func nextSentence() { guard !spans.isEmpty else { return }; sentenceIndex += 1; if sentenceIndex >= spans.count { Task { await advanceChapter(1) } } else { speakCurrent() } }
    func previousSentence() { guard !spans.isEmpty else { return }; sentenceIndex = max(0, sentenceIndex - 1); speakCurrent() }
    func setSleepTimer(_ plan: SleepTimerPlan?) { sleepTimer = plan.map(SleepTimerPlanner.start) }

    private func loadChapter(offset: Int) async {
        guard chapters.indices.contains(chapterIndex) else { stop(); return }
        do {
            body = try await LibraryRepository.shared.chapterText(chapters[chapterIndex])
            spans = SentenceSegmenter.segment(body)
            sentenceIndex = SentenceSegmenter.indexAt(spans, offset: max(0, offset))
            if sentenceIndex >= spans.count { sentenceIndex = max(0, spans.count - 1) }
            onChapterChanged?(chapterIndex, spans.indices.contains(sentenceIndex) ? spans[sentenceIndex].start : 0)
            updateNowPlaying()
        } catch { stop() }
    }

    private func speakCurrent() {
        guard isActive, spans.indices.contains(sentenceIndex) else {
            if isActive { Task { await advanceChapter(1) } }
            return
        }
        let span = spans[sentenceIndex]
        currentRange = NSRange(location: span.start, length: span.length)
        onPositionChanged?(chapterIndex, span.start)
        let rules = ReaderEnhancementSettingsStore.shared.settings.replacementRules
        let purified = ReaderTextReplacementEngine.listeningText(body, start: span.start, end: span.end, rules: rules)
        if purified.display.isEmpty { advanceAfterSpeech(); return }
        tts.speak(purified.display, baseUTF16Offset: span.start, mapping: purified.mapping)
        updateNowPlaying()
    }

    private func advanceAfterSpeech() {
        guard isActive else { return }
        if var state = sleepTimer {
            state = SleepTimerPlanner.tick(state, elapsedMillis: 0, playing: true)
            sleepTimer = state
            if SleepTimerPlanner.isExpired(state) { stop(); return }
        }
        sentenceIndex += 1
        if sentenceIndex >= spans.count { Task { await advanceChapter(1) } }
        else { speakCurrent() }
    }

    private func advanceChapter(_ delta: Int) async {
        let next = chapterIndex + delta
        guard chapters.indices.contains(next) else { stop(); return }
        if delta > 0, var state = sleepTimer {
            state = SleepTimerPlanner.onChapterCompleted(state)
            sleepTimer = state
            if SleepTimerPlanner.isExpired(state) { stop(); return }
        }
        chapterIndex = next
        await loadChapter(offset: delta < 0 ? max(0, chapters[next].charCount - 1) : 0)
        speakCurrent()
    }

    private func installRemoteCommands() {
        let remote = MediaRemoteController.shared; remote.install()
        remote.onPlay = { [weak self] in self?.tts.resume() }
        remote.onPause = { [weak self] in self?.tts.pause() }
        remote.onToggle = { [weak self] in self?.toggle() }
        remote.onNext = { [weak self] in self?.nextSentence() }
        remote.onPrevious = { [weak self] in self?.previousSentence() }
    }

    private func updateNowPlaying() {
        guard let book, chapters.indices.contains(chapterIndex) else { return }
        MediaRemoteController.shared.update(bookTitle: book.title, chapterTitle: chapters[chapterIndex].title, chapterIndex: chapterIndex + 1, chapterCount: chapters.count, playing: tts.isSpeaking)
    }

    private func startTimer() {
        lastTick = Date(); timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date(); let elapsed = Int64(max(0, now.timeIntervalSince(self.lastTick) * 1000)); self.lastTick = now
                if var state = self.sleepTimer {
                    state = SleepTimerPlanner.tick(state, elapsedMillis: elapsed, playing: self.tts.isSpeaking)
                    self.sleepTimer = state
                    if SleepTimerPlanner.isExpired(state) { self.stop() }
                }
            }
        }
    }
}
