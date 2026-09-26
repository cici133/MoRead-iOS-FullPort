import Foundation
import SwiftUI

struct APICallLogEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var startedAt: Date
    var durationMs: Int64
    var method: String
    var url: String
    var statusCode: Int?
    var requestBytes: Int
    var responseBytes: Int
    var category: String
    var errorType: String?
}

@MainActor
final class APICallLogStore: ObservableObject {
    static let shared = APICallLogStore()
    @AppStorage("api.log.enabled") var enabled = false
    @Published private(set) var entries: [APICallLogEntry] = []
    private let url: URL
    private let maxEntries = 500

    private init() {
        let root = (try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory
        url = root.appendingPathComponent("api-call-log.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([APICallLogEntry].self, from: data) { entries = decoded }
    }

    func append(_ entry: APICallLogEntry) {
        guard enabled else { return }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        persist()
    }

    func clear() { entries = []; try? FileManager.default.removeItem(at: url) }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}

enum APICallLogger {
    static func redactedURL(_ url: URL?) -> String {
        guard let url else { return "" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let sensitive = Set(["key", "api_key", "apikey", "token", "access_token", "authorization"])
        components.queryItems = components.queryItems?.map { item in sensitive.contains(item.name.lowercased()) ? URLQueryItem(name: item.name, value: "[redacted]") : item }
        return components.string ?? url.absoluteString
    }

    static func record(request: URLRequest, startedAt: Date, response: HTTPURLResponse?, responseBytes: Int, category: String, error: Error? = nil) async {
        let enabled = await MainActor.run { APICallLogStore.shared.enabled }
        guard enabled else { return }
        let entry = APICallLogEntry(
            startedAt: startedAt,
            durationMs: Int64(Date().timeIntervalSince(startedAt) * 1000),
            method: request.httpMethod ?? "GET",
            url: redactedURL(request.url),
            statusCode: response?.statusCode,
            requestBytes: request.httpBody?.count ?? 0,
            responseBytes: responseBytes,
            category: category,
            errorType: error.map { String(describing: type(of: $0)) }
        )
        await MainActor.run { APICallLogStore.shared.append(entry) }
    }
}
