import Foundation

enum ProactiveMediaKind: String, Codable, Sendable { case voice, image }

actor ProactiveAnnotationQuotaStore {
    static let shared = ProactiveAnnotationQuotaStore()
    private struct State: Codable { var epochDay: Int; var voices: Int; var images: Int }
    private let url: URL
    private var state: State

    init() {
        let root = (try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory
        url = root.appendingPathComponent("proactive-annotation-quota.json")
        let day = Self.epochDay()
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(State.self, from: data), saved.epochDay == day {
            state = saved
        } else { state = .init(epochDay: day, voices: 0, images: 0) }
    }

    /// Charges before a paid media request, mirroring Android. A failed/crashed request does not
    /// silently return the quota and cause repeated paid retries.
    func reserve(_ kind: ProactiveMediaKind, limit: Int) -> Bool {
        resetIfNeeded()
        if limit == ProactiveAnnotationLimits.unlimited { increment(kind); return true }
        guard limit > 0 else { return false }
        switch kind {
        case .voice: guard state.voices < limit else { return false }
        case .image: guard state.images < limit else { return false }
        }
        increment(kind); return true
    }

    func snapshot() -> (voices: Int, images: Int) { resetIfNeeded(); return (state.voices, state.images) }

    private func increment(_ kind: ProactiveMediaKind) {
        switch kind { case .voice: state.voices += 1; case .image: state.images += 1 }
        persist()
    }
    private func resetIfNeeded() {
        let day = Self.epochDay()
        if state.epochDay != day { state = .init(epochDay: day, voices: 0, images: 0); persist() }
    }
    private func persist() { if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) } }
    private static func epochDay() -> Int { Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 / 86_400) }
}

struct AnnotationMediaPayload: Codable, Hashable, Sendable {
    var audioPath: String? = nil
    var illustrationId: Int64? = nil
    func json() -> String { (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "{}" }
}
