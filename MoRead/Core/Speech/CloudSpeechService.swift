import AVFoundation
import CryptoKit
import Foundation

struct SynthesizedSpeech: Sendable {
    var data: Data
    var mediaType: String
    var generationId: String?
}

enum CloudSpeechError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

actor CloudSpeechService {
    static let shared = CloudSpeechService()

    func synthesize(
        text: String,
        voice: String? = nil,
        emotion: String? = nil,
        instruction: String? = nil,
        settings: TTSSettings? = nil
    ) async throws -> SynthesizedSpeech {
        let config: TTSSettings
        if let settings { config = settings }
        else { config = await MainActor.run { TTSSettingsStore.shared.settings } }
        let key = await MainActor.run { TTSSettingsStore.shared.currentKey() }
        guard config.configured, !key.isEmpty else {
            throw CloudSpeechError.invalid("请先配置云 TTS 与 API Key")
        }
        switch config.aiProvider {
        case .gemini:
            return try await gemini(text: text, voice: voice ?? config.aiVoiceId, config: config, key: key, instruction: instruction)
        case .minimaxCN, .minimaxIntl:
            return try await minimax(text: text, voice: voice ?? config.aiVoiceId, config: config, key: key, emotion: emotion, instruction: instruction)
        case .openAICompatible:
            return try await openAI(text: text, voice: voice ?? config.aiVoiceId, config: config, key: key, instruction: instruction)
        }
    }

    func cachedSpeech(text: String, voice: String, emotion: String? = nil, instruction: String? = nil, settings: TTSSettings? = nil, bookId: Int64? = nil) async throws -> URL {
        let config: TTSSettings
        if let settings { config = settings }
        else { config = await MainActor.run { TTSSettingsStore.shared.settings } }
        let signature = "\(config.aiProvider.rawValue)|\(config.aiBaseURL)|\(config.aiModel)|\(voice)|\(config.aiSpeed)|\(emotion ?? "")|\(instruction ?? "")|\(text)"
        let digest = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = AppPaths.speechCache(bookId: bookId)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(digest + ".audio")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let value = try await synthesize(text: text, voice: voice, emotion: emotion, instruction: instruction, settings: config)
        try value.data.write(to: file, options: .atomic)
        return file
    }

    private func openAI(text: String, voice: String, config: TTSSettings, key: String, instruction: String?) async throws -> SynthesizedSpeech {
        let base: String
        do { base = try NetworkEndpointPolicy.normalizedServiceBaseURL(config.aiBaseURL) }
        catch { throw CloudSpeechError.invalid(error.localizedDescription) }
        guard let url = URL(string: base + "/audio/speech") else { throw CloudSpeechError.invalid("TTS 地址无效") }
        var body: [String: Any] = [
            "model": config.aiModel,
            "input": text,
            "voice": voice.isEmpty ? "alloy" : voice,
            "response_format": "mp3",
            "speed": min(4, max(0.25, config.aiSpeed))
        ]
        if let instruction, !instruction.isEmpty { body["instructions"] = instruction }
        let data = try await request(url: url, key: key, body: body)
        return .init(data: data, mediaType: "audio/mpeg", generationId: nil)
    }

    private func minimax(text: String, voice: String, config: TTSSettings, key: String, emotion: String?, instruction: String?) async throws -> SynthesizedSpeech {
        let base: String
        do { base = try NetworkEndpointPolicy.normalizedServiceBaseURL(config.aiBaseURL) }
        catch { throw CloudSpeechError.invalid(error.localizedDescription) }
        guard let url = URL(string: base + "/t2a_v2") else { throw CloudSpeechError.invalid("MiniMax 地址无效") }
        var voiceSetting: [String: Any] = [
            "voice_id": voice,
            "speed": min(2, max(0.5, config.aiSpeed)),
            "vol": min(10, max(0, config.aiVolume)),
            "pitch": min(12, max(-12, config.aiPitch))
        ]
        if let emotion, !emotion.isEmpty { voiceSetting["emotion"] = emotion }
        var body: [String: Any] = [
            "model": config.aiModel,
            "text": text,
            "stream": false,
            "voice_setting": voiceSetting,
            "audio_setting": ["format": "mp3", "sample_rate": 32000, "bitrate": 128000, "channel": 1]
        ]
        if !config.aiGroupId.isEmpty { body["group_id"] = config.aiGroupId }
        if let instruction, !instruction.isEmpty { body["instruction"] = instruction }
        let raw = try await request(url: url, key: key, body: body)
        guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw CloudSpeechError.invalid("无法解析 MiniMax TTS 响应")
        }
        let encoded = ((root["data"] as? [String: Any])?["audio"] as? String) ?? (root["audio"] as? String)
        guard let encoded, let data = Data(base64Encoded: encoded) ?? Data(hexString: encoded), !data.isEmpty else {
            throw CloudSpeechError.invalid("MiniMax 未返回音频")
        }
        return .init(data: data, mediaType: "audio/mpeg", generationId: root["trace_id"] as? String)
    }

    private func gemini(text: String, voice: String, config: TTSSettings, key: String, instruction: String?) async throws -> SynthesizedSpeech {
        let base: String
        do { base = try NetworkEndpointPolicy.normalizedServiceBaseURL(config.aiBaseURL) }
        catch { throw CloudSpeechError.invalid(error.localizedDescription) }
        guard let url = URL(string: "\(base)/models/\(config.aiModel):generateContent") else {
            throw CloudSpeechError.invalid("Gemini TTS 地址无效")
        }
        let prompt = ((instruction?.isEmpty == false) ? instruction! + "\n\n" : "") + text
        let voiceName = voice.isEmpty ? "Kore" : voice
        let speechConfig: [String: Any] = [
            "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voiceName]]
        ]
        let generationConfig: [String: Any] = [
            "responseModalities": ["AUDIO"],
            "speechConfig": speechConfig
        ]
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": generationConfig
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        await APICallLogger.record(request: req, startedAt: started, response: http, responseBytes: data.count, category: "TTS")
        guard let http, (200..<300).contains(http.statusCode) else {
            throw CloudSpeechError.invalid(String(data: data, encoding: .utf8) ?? "Gemini TTS 请求失败")
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let inline = parts.compactMap({ $0["inlineData"] as? [String: Any] }).first,
            let b64 = inline["data"] as? String,
            let pcm = Data(base64Encoded: b64)
        else { throw CloudSpeechError.invalid("Gemini TTS 未返回音频") }
        let mime = inline["mimeType"] as? String ?? "audio/L16;rate=24000"
        let audio = mime.lowercased().contains("wav") ? pcm : Self.pcm16MonoToWav(pcm, rate: Self.rate(from: mime) ?? 24000)
        return .init(data: audio, mediaType: "audio/wav", generationId: nil)
    }

    private func request(url: URL, key: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        await APICallLogger.record(request: req, startedAt: started, response: http, responseBytes: data.count, category: "TTS")
        guard let http, (200..<300).contains(http.statusCode) else {
            throw CloudSpeechError.invalid(String(data: data, encoding: .utf8) ?? "TTS 请求失败")
        }
        guard data.count <= 30 * 1024 * 1024 else { throw CloudSpeechError.invalid("生成语音超过 30 MB") }
        return data
    }

    private static func rate(from mime: String) -> Int? {
        guard let r = mime.range(of: "rate=") else { return nil }
        return Int(mime[r.upperBound...].prefix { $0.isNumber })
    }

    private static func pcm16MonoToWav(_ pcm: Data, rate: Int) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + pcm.count)); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16); text("data"); u32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

private extension Data {
    init?(hexString: String) {
        let string = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard string.count % 2 == 0 else { return nil }
        var output = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            output.append(byte); index = next
        }
        self = output
    }
}
