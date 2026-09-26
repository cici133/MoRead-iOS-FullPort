import AVFoundation
import Foundation

@MainActor
final class TTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var highlightedRange: NSRange?
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    @Published var pitch: Float = 1
    @Published var volume: Float = 1
    @Published var voiceIdentifier: String = ""

    var onFinished: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var baseUTF16Offset = 0
    private var activeMapping: ReaderTextMapping?

    override init() { super.init(); synthesizer.delegate = self }

    var systemVoices: [AVSpeechSynthesisVoice] { AVSpeechSynthesisVoice.speechVoices().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    func speak(_ text: String, baseUTF16Offset: Int = 0, language: String = "zh-CN", mapping: ReaderTextMapping? = nil) {
        if synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
        self.baseUTF16Offset = baseUTF16Offset
        self.activeMapping = mapping
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
        utterance.pitchMultiplier = min(2, max(0.5, pitch)); utterance.volume = min(1, max(0, volume))
        utterance.voice = voiceIdentifier.isEmpty ? AVSpeechSynthesisVoice(language: language) : AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        configureAudioSession(); synthesizer.speak(utterance); isSpeaking = true
    }

    func speak(body: String, span: SentenceSpan, language: String = "zh-CN") {
        let text = SentenceSegmenter.speakableText(body, start: span.start, end: span.end)
        guard !text.isEmpty else { onFinished?(); return }
        speak(text, baseUTF16Offset: span.start, language: language)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate); isSpeaking = false; highlightedRange = nil }
    func pause() { if synthesizer.pauseSpeaking(at: .word) { isSpeaking = false } }
    func resume() { if synthesizer.continueSpeaking() { isSpeaking = true } }
    func pauseOrResume() { synthesizer.isPaused ? resume() : pause() }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch { }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        if let mapping = activeMapping {
            let source = mapping.sourceRange(displayStart: characterRange.location, displayEnd: characterRange.location + characterRange.length)
            highlightedRange = NSRange(location: baseUTF16Offset + source.location, length: source.length)
        } else {
            highlightedRange = NSRange(location: baseUTF16Offset + characterRange.location, length: characterRange.length)
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { isSpeaking = false; highlightedRange = nil; onFinished?() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { isSpeaking = false; highlightedRange = nil }
}
