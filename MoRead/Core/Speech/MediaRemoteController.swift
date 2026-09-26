import Foundation
import MediaPlayer

@MainActor
final class MediaRemoteController {
    static let shared = MediaRemoteController()
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    private var tokens: [Any] = []
    private var installed = false

    func install() {
        guard !installed else { return }; installed = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true; center.pauseCommand.isEnabled = true; center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true; center.previousTrackCommand.isEnabled = true
        tokens.append(center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.onPlay?() }; return .success })
        tokens.append(center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.onPause?() }; return .success })
        tokens.append(center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.onToggle?() }; return .success })
        tokens.append(center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.onNext?() }; return .success })
        tokens.append(center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.onPrevious?() }; return .success })
    }

    func update(bookTitle: String, chapterTitle: String, chapterIndex: Int, chapterCount: Int, playing: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapterTitle,
            MPMediaItemPropertyAlbumTitle: bookTitle,
            MPNowPlayingInfoPropertyChapterNumber: chapterIndex,
            MPNowPlayingInfoPropertyChapterCount: chapterCount,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
}
