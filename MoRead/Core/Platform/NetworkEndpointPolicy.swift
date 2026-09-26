import Foundation

enum NetworkEndpointPolicy {
    struct ValidationError: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    /// MoRead accepts HTTPS everywhere. Clear-text HTTP is reserved for explicitly local/self-hosted
    /// endpoints so the iOS port keeps the Android BYOK/LAN capability without silently widening it
    /// to arbitrary public HTTP services.
    static func normalizedServiceBaseURL(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: value), let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty else {
            throw ValidationError(message: "服务地址无效")
        }
        guard scheme == "https" || scheme == "http" else {
            throw ValidationError(message: "服务地址必须使用 HTTPS，或可信局域网 HTTP")
        }
        if scheme == "http", !isTrustedLocalHost(host) {
            throw ValidationError(message: "公网服务必须使用 HTTPS；HTTP 只允许 localhost、回环或可信局域网地址")
        }
        // Credentials belong in Keychain, never in the URL itself.
        guard components.user == nil, components.password == nil else {
            throw ValidationError(message: "请不要把账号或密码写进服务 URL")
        }
        components.fragment = nil
        guard let normalized = components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !normalized.isEmpty else {
            throw ValidationError(message: "服务地址无效")
        }
        return normalized
    }

    static func validatedServiceURL(_ raw: String) throws -> URL {
        guard let url = URL(string: try normalizedServiceBaseURL(raw)) else { throw ValidationError(message: "服务地址无效") }
        return url
    }

    static func isTrustedLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        // Unqualified hostnames are resolved by the user's LAN/DNS search domain. They cannot name
        // an ordinary public DNS FQDN, so keep them available for NAS / local model servers.
        if !host.contains(".") && !host.contains(":") { return true }
        if let v4 = ipv4(host) {
            let a=v4[0], b=v4[1]
            return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
        }
        if host.contains(":") {
            // IPv6 loopback, unique-local fc00::/7, and link-local fe80::/10.
            if host == "0:0:0:0:0:0:0:1" { return true }
            let first = host.split(separator: ":", omittingEmptySubsequences: true).first.flatMap { UInt16($0, radix:16) }
            if let first { return (first & 0xFE00) == 0xFC00 || (first & 0xFFC0) == 0xFE80 }
        }
        return false
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return values
    }
}
