import SwiftUI
import AVFoundation
import UIKit

@MainActor
private final class AnnotationAudioPlaybackState: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    var player: AVAudioPlayer?

    func toggle(_ url: URL) throws {
        if playing {
            player?.pause()
            playing = false
            return
        }
        if player?.url != url {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
        }
        guard player?.play() == true else {
            playing = false
            throw AnnotationMediaError.audioPlaybackFailed
        }
        playing = true
    }

    func stop() {
        player?.stop()
        playing = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playing = false
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        playing = false
    }
}

private enum AnnotationMediaError: LocalizedError {
    case audioPlaybackFailed
    var errorDescription: String? { "无法播放这段语音" }
}

struct AnnotationMediaView: View {
    let mediaJSON: String
    var compact = false
    @State private var imagePath: String?
    @State private var imageResolved = false
    @State private var errorText: String?
    @StateObject private var audio = AnnotationAudioPlaybackState()

    private var payload: AnnotationMediaPayload? {
        guard let data = mediaJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnnotationMediaPayload.self, from: data)
    }
    private var hasMedia: Bool {
        guard let payload else { return false }
        return !(payload.audioPath?.isEmpty ?? true) || payload.illustrationId != nil
    }
    private var audioPath: String? { payload?.audioPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    private var audioExists: Bool { audioPath.map(FileManager.default.fileExists(atPath:)) ?? false }
    private var imageExists: Bool { imagePath.map(FileManager.default.fileExists(atPath:)) ?? false }

    var body: some View {
        if hasMedia {
            VStack(alignment: .leading, spacing: 8) {
                if let imagePath, imageExists, let image = UIImage(contentsOfFile: imagePath) {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .frame(maxHeight: compact ? 160 : 360)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contextMenu {
                            ShareLink(item: URL(fileURLWithPath: imagePath)) { Label("分享图片", systemImage: "square.and.arrow.up") }
                        }
                } else if payload?.illustrationId != nil, imageResolved {
                    missingMediaRow("插图文件已失效或已被清理", systemImage: "photo.badge.exclamationmark")
                }

                if let audioPath, audioExists {
                    let url = URL(fileURLWithPath: audioPath)
                    HStack(spacing: 10) {
                        Button {
                            do { try audio.toggle(url) }
                            catch { errorText = error.localizedDescription }
                        } label: {
                            Label(audio.playing ? "暂停语音" : "播放语音", systemImage: audio.playing ? "pause.circle.fill" : "play.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                } else if audioPath != nil {
                    missingMediaRow("语音文件已失效或已被清理", systemImage: "waveform.badge.exclamationmark")
                }
            }
            .task(id: payload?.illustrationId) { await loadImage() }
            .onDisappear { audio.stop() }
            .alert("媒体播放失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) { }
            } message: { Text(errorText ?? "") }
        }
    }

    @ViewBuilder
    private func missingMediaRow(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            .accessibilityHint("可在设置的存储管理中清理无效缓存与孤儿文件")
    }

    @MainActor
    private func loadImage() async {
        imageResolved = false
        defer { imageResolved = true }
        guard let id = payload?.illustrationId else { imagePath = nil; return }
        imagePath = try? await ImageGenerationService.shared.illustration(id: id)?.imagePath
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
