import Foundation
import CryptoKit

struct GeminiVoiceDesignRequest: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var gender: String = "female"
    var language: String = "zh-CN"
}

struct GeminiDesignedVoice: Sendable {
    var id: String
    var previewData: Data?
}

enum VoiceDesignError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let value) = self { value } else { nil } }
}

actor VoiceDesignService {
    static let shared = VoiceDesignService()
    private let session = URLSession.shared

    func design(_ design: GeminiVoiceDesignRequest) async throws -> GeminiDesignedVoice {
        try validate(design)
        let config = await MainActor.run { TTSSettingsStore.shared.settings }
        let key = await MainActor.run { TTSSettingsStore.shared.currentKey() }
        guard config.aiProvider == .gemini, !key.isEmpty else { throw VoiceDesignError.invalid("请先在语音朗读中配置 Gemini TTS 与 API Key") }
        let body: [String: Any] = [
            "store": true,
            "voice": [
                "model": config.aiModel.replacingOccurrences(of: "models/", with: ""),
                "type": "prompted",
                "display_name": design.name.trimmingCharacters(in: .whitespacesAndNewlines),
                "gender": design.gender,
                "language_code": design.language,
                "prompted": ["input": design.description.trimmingCharacters(in: .whitespacesAndNewlines)]
            ]
        ]
        let root = try await request(path: "/voices", method: "POST", body: body, config: config, key: key)
        let id = root["id"] as? String ?? ""
        try requireDesignedId(id)
        let preview = (root["sample_audio"] as? [String: Any]).flatMap { try? decodeAudio($0) }
        return .init(id: id, previewData: preview)
    }

    func preview(id: String) async throws -> Data {
        try requireDesignedId(id)
        let config = await MainActor.run { TTSSettingsStore.shared.settings }
        let key = await MainActor.run { TTSSettingsStore.shared.currentKey() }
        guard config.aiProvider == .gemini, !key.isEmpty else { throw VoiceDesignError.invalid("请先配置 Gemini TTS") }
        let root = try await request(path: "/voices/\(id)", method: "GET", body: nil, config: config, key: key)
        guard let audio = root["sample_audio"] as? [String: Any] else { throw VoiceDesignError.invalid("音色已生成，但服务暂未提供试听，请稍后重试") }
        return try decodeAudio(audio)
    }

    func delete(id: String) async {
        guard (try? requireDesignedId(id)) != nil else { return }
        let config = await MainActor.run { TTSSettingsStore.shared.settings }
        let key = await MainActor.run { TTSSettingsStore.shared.currentKey() }
        guard config.aiProvider == .gemini, !key.isEmpty else { return }
        _ = try? await request(path: "/voices/\(id)", method: "DELETE", body: nil, config: config, key: key, allowEmpty: true)
    }

    func savePreview(id: String, data: Data) throws -> URL {
        guard !data.isEmpty, data.count <= 30 * 1024 * 1024 else { throw VoiceDesignError.invalid("试听音频无效或过大") }
        let root = try MoReadDatabase.applicationDirectory().appendingPathComponent("voice-design-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let digest = Self.sha256Hex(Data(id.utf8))
        let file = root.appendingPathComponent(digest + ".wav")
        try data.write(to: file, options: .atomic)
        return file
    }

    func previewURL(id: String) -> URL? {
        guard let root = try? MoReadDatabase.applicationDirectory().appendingPathComponent("voice-design-previews", isDirectory: true) else { return nil }
        let file = root.appendingPathComponent(Self.sha256Hex(Data(id.utf8)) + ".wav")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    func removePreview(id: String) { if let url = previewURL(id: id) { try? FileManager.default.removeItem(at: url) } }

    private static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func validate(_ d: GeminiVoiceDesignRequest) throws {
        guard !d.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, d.name.count <= 80 else { throw VoiceDesignError.invalid("请填写 80 字以内的音色名称") }
        guard !d.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, d.description.count <= 2000 else { throw VoiceDesignError.invalid("请填写 2000 字以内的声音描述") }
        guard ["female", "male", "neutral"].contains(d.gender) else { throw VoiceDesignError.invalid("声音类型无效") }
        let regex = try NSRegularExpression(pattern: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$")
        let range = NSRange(d.language.startIndex..<d.language.endIndex, in: d.language)
        guard regex.firstMatch(in: d.language, range: range) != nil else { throw VoiceDesignError.invalid("语言代码无效") }
    }

    private func requireDesignedId(_ id: String) throws {
        let regex = try NSRegularExpression(pattern: "^voice_[A-Za-z0-9_-]+$")
        guard regex.firstMatch(in: id, range: NSRange(location: 0, length: (id as NSString).length)) != nil else { throw VoiceDesignError.invalid("服务未返回有效的自定义音色 ID") }
    }

    private func base(_ config: TTSSettings) throws -> String {
        var value: String
        do { value = try NetworkEndpointPolicy.normalizedServiceBaseURL(config.aiBaseURL) }
        catch { throw VoiceDesignError.invalid(error.localizedDescription) }
        if value.hasSuffix("/v1beta") { value.removeLast("/v1beta".count) }
        else if value.hasSuffix("/v1") { value.removeLast("/v1".count) }
        return value + "/v1beta"
    }

    private func request(path: String, method: String, body: [String: Any]?, config: TTSSettings, key: String, allowEmpty: Bool = false) async throws -> [String: Any] {
        guard let url = URL(string: try base(config) + path) else { throw VoiceDesignError.invalid("Gemini 音色地址无效") }
        var req = URLRequest(url: url); req.httpMethod = method; req.setValue(key, forHTTPHeaderField: "x-goog-api-key"); req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let started = Date()
        let (data, response) = try await session.data(for: req)
        let http = response as? HTTPURLResponse
        await APICallLogger.record(request: req, startedAt: started, response: http, responseBytes: data.count, category: "VoiceDesign")
        guard let http else { throw VoiceDesignError.invalid("Gemini 音色服务无响应") }
        if allowEmpty, (200..<300).contains(http.statusCode), data.isEmpty { return [:] }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data.prefix(8_192), encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw VoiceDesignError.invalid("Gemini 音色请求失败（HTTP \(http.statusCode)）：\(detail.replacingOccurrences(of: key, with: "[redacted]"))")
        }
        if data.isEmpty { return [:] }
        guard data.count <= 42 * 1024 * 1024, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VoiceDesignError.invalid("Gemini 音色响应格式无效") }
        return root
    }

    private func decodeAudio(_ object: [String: Any]) throws -> Data {
        let encoded = object["data"] as? String ?? ""
        guard encoded.count <= 40 * 1024 * 1024, let raw = Data(base64Encoded: encoded), !raw.isEmpty, raw.count <= 30 * 1024 * 1024 else { throw VoiceDesignError.invalid("Gemini 返回了无效试听音频") }
        let mime = (object["mime_type"] as? String ?? "audio/wav").lowercased()
        if mime.hasPrefix("audio/wav") || mime.hasPrefix("audio/wave") || mime.hasPrefix("audio/x-wav") {
            guard raw.count >= 44, String(data: raw.prefix(4), encoding: .ascii) == "RIFF" else { throw VoiceDesignError.invalid("Gemini 返回的 WAV 无效") }
            return raw
        }
        if mime.hasPrefix("audio/l16") || mime.hasPrefix("audio/pcm") {
            let rate = Int(mime.split(separator: ";").first(where: { $0.contains("rate=") })?.split(separator: "=").last ?? "24000") ?? 24_000
            return wav(pcm: raw, sampleRate: min(96_000, max(8_000, rate)))
        }
        throw VoiceDesignError.invalid("Gemini 返回了不支持的试听格式")
    }

    private func wav(pcm: Data, sampleRate: Int) -> Data {
        var out = Data(); func append(_ s: String) { out.append(Data(s.utf8)) }; func u16(_ v: UInt16) { var x=v.littleEndian; out.append(Data(bytes:&x,count:2)) }; func u32(_ v: UInt32) { var x=v.littleEndian; out.append(Data(bytes:&x,count:4)) }
        append("RIFF"); u32(UInt32(pcm.count + 36)); append("WAVEfmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16); append("data"); u32(UInt32(pcm.count)); out.append(pcm); return out
    }
}
