import Foundation

struct AppUpdateStatus: Sendable {
    var currentVersion: String
    var latestVersion: String?
    var releaseName: String?
    var releaseURL: URL?
    var publishedAt: Date?
    var updateAvailable: Bool
    var error: String?
}

actor AppUpdateService {
    static let shared = AppUpdateService()
    private let endpoint = URL(string: "https://api.github.com/repos/ovo066/MoRead/releases/latest")!

    func check() async -> AppUpdateStatus {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MoRead-iOS/\(current)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return .init(currentVersion: current, latestVersion: nil, releaseName: nil, releaseURL: nil, publishedAt: nil, updateAvailable: false, error: "GitHub Release 检查失败")
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .init(currentVersion: current, latestVersion: nil, releaseName: nil, releaseURL: nil, publishedAt: nil, updateAvailable: false, error: "无法解析 Release 信息")
            }
            let tag = (root["tag_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let latest = tag?.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let url = (root["html_url"] as? String).flatMap(URL.init(string:))
            let published = (root["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            return .init(
                currentVersion: current,
                latestVersion: latest,
                releaseName: root["name"] as? String,
                releaseURL: url,
                publishedAt: published,
                updateAvailable: latest.map { Self.compare($0, current) == .orderedDescending } ?? false,
                error: nil
            )
        } catch {
            return .init(currentVersion: current, latestVersion: nil, releaseName: nil, releaseURL: nil, publishedAt: nil, updateAvailable: false, error: error.localizedDescription)
        }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func components(_ value: String) -> [Int] {
            value.split(separator: ".").map { part in
                Int(part.prefix { $0.isNumber }) ?? 0
            }
        }
        let a = components(lhs), b = components(rhs), count = max(a.count, b.count)
        for index in 0..<count {
            let av = index < a.count ? a[index] : 0, bv = index < b.count ? b[index] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }
}
