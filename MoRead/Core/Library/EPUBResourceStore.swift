import Foundation
import ZIPFoundation

actor EPUBResourceStore {
    static let shared = EPUBResourceStore()
    private static let bridgeMarker = ".moread-uri-bridge-v2"

    func extractedRoot(bookId: Int64) throws -> URL {
        try MoReadDatabase.applicationDirectory().appendingPathComponent("books",isDirectory:true).appendingPathComponent(String(bookId),isDirectory:true).appendingPathComponent("expanded",isDirectory:true)
    }

    @discardableResult func prepare(bookId:Int64,epubURL:URL) throws->URL{
        let root=try extractedRoot(bookId:bookId)
        let container = root.appendingPathComponent("META-INF/container.xml")
        if FileManager.default.fileExists(atPath:container.path) {
            try bridgeLocalResourceURIsIfNeeded(root: root)
            return root
        }
        try? FileManager.default.removeItem(at:root)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        guard let archive=Archive(url:epubURL,accessMode:.read) else{throw ResourceError.invalidArchive}
        for entry in archive {
            let clean=entry.path.replacingOccurrences(of:"\\",with:"/")
            guard !clean.hasPrefix("/"),!clean.split(separator:"/").contains("..") else{continue}
            let target=root.appendingPathComponent(clean)
            guard Self.isInside(target, root: root) else{continue}
            if entry.type == .directory {try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true);continue}
            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            _ = try archive.extract(entry,to:target)
        }
        try bridgeLocalResourceURIsIfNeeded(root: root)
        return root
    }

    /// WebKit interprets `:`, `#` and `?` in relative references as URI syntax even when those
    /// characters are literally part of a ZIP entry name. Android uses EpubUriContainer for the
    /// same class of EPUB. iOS keeps the original archive untouched and rewrites only the private
    /// extracted copy so confirmed local references use percent-encoded path segments.
    private func bridgeLocalResourceURIsIfNeeded(root: URL) throws {
        let marker = root.appendingPathComponent(Self.bridgeMarker)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
        var documents: [URL] = []
        for case let file as URL in enumerator {
            let ext = file.pathExtension.lowercased()
            if ["xhtml","html","htm","css","svg"].contains(ext) { documents.append(file) }
        }
        for file in documents { try rewriteReferences(in: file, root: root) }
        try Data("moread-uri-bridge-v2".utf8).write(to: marker, options: .atomic)
    }

    private func rewriteReferences(in file: URL, root: URL) throws {
        let data = try Data(contentsOf: file)
        guard data.count <= 16 * 1024 * 1024 else { return }
        let encoding = detectTextEncoding(data)
        guard var text = String(data: data, encoding: encoding) else { return }
        let original = text

        // Quoted HTML/XML attributes: href/src/xlink:href/poster/data.
        let attributePattern = #"(?i)\b(href|src|xlink:href|poster|data)\s*=\s*([\"'])(.*?)\2"#
        text = replace(pattern: attributePattern, in: text) { match, source in
            guard match.numberOfRanges >= 4 else { return nil }
            let name = (source as NSString).substring(with: match.range(at: 1))
            let quote = (source as NSString).substring(with: match.range(at: 2))
            let value = (source as NSString).substring(with: match.range(at: 3))
            guard let rewritten = rewriteLocalReference(value, from: file, root: root), rewritten != value else { return nil }
            return "\(name)=\(quote)\(rewritten)\(quote)"
        }
        // CSS url(...) and @import strings, including CSS embedded inside XHTML/SVG style blocks.
        let urlPattern = #"(?i)url\(\s*([\"']?)(.*?)\1\s*\)"#
        text = replace(pattern: urlPattern, in: text) { match, source in
            guard match.numberOfRanges >= 3 else { return nil }
            let quote = (source as NSString).substring(with: match.range(at: 1))
            let value = (source as NSString).substring(with: match.range(at: 2))
            guard let rewritten = rewriteLocalReference(value, from: file, root: root), rewritten != value else { return nil }
            return "url(\(quote)\(rewritten)\(quote))"
        }
        let importPattern = #"(?i)@import\s+([\"'])(.*?)\1"#
        text = replace(pattern: importPattern, in: text) { match, source in
            guard match.numberOfRanges >= 3 else { return nil }
            let quote = (source as NSString).substring(with: match.range(at: 1))
            let value = (source as NSString).substring(with: match.range(at: 2))
            guard let rewritten = rewriteLocalReference(value, from: file, root: root), rewritten != value else { return nil }
            return "@import \(quote)\(rewritten)\(quote)"
        }
        if text != original, let out = text.data(using: encoding) { try out.write(to: file, options: .atomic) }
    }

    private func rewriteLocalReference(_ raw: String, from document: URL, root: URL) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else { return nil }
        let decodedWhole = trimmed.removingPercentEncoding ?? trimmed
        let documentDirectory = document.deletingLastPathComponent()

        // First test the entire value as a literal filename. This is what makes `a#b.png`,
        // `font?1.otf` and `foo:bar.svg` work instead of being parsed as fragment/query/scheme.
        if let literal = localTarget(decodedWhole, from: documentDirectory, root: root), FileManager.default.fileExists(atPath: literal.path) {
            return encodeRelativeReference(decodedWhole)
        }
        if isExternalScheme(trimmed) { return nil }

        let split = splitPathQueryFragment(trimmed)
        guard !split.path.isEmpty else { return nil }
        let decodedPath = split.path.removingPercentEncoding ?? split.path
        guard let candidate = localTarget(decodedPath, from: documentDirectory, root: root), Self.isInside(candidate, root: root) else { return nil }
        // Rewrite even if missing: percent encoding still makes a syntactically local URI safer,
        // while broken EPUB references remain broken rather than being redirected elsewhere.
        return encodeRelativeReference(decodedPath) + split.query + split.fragment
    }

    private func localTarget(_ path: String, from directory: URL, root: URL) -> URL? {
        let candidate: URL
        if path.hasPrefix("/") { candidate = root.appendingPathComponent(String(path.dropFirst())) }
        else { candidate = directory.appendingPathComponent(path) }
        let standardized = candidate.standardizedFileURL
        return Self.isInside(standardized, root: root) ? standardized : nil
    }

    private func splitPathQueryFragment(_ raw: String) -> (path: String, query: String, fragment: String) {
        var path = raw, query = "", fragment = ""
        if let hash = path.firstIndex(of: "#") { fragment = String(path[hash...]); path = String(path[..<hash]) }
        if let q = path.firstIndex(of: "?") { query = String(path[q...]); path = String(path[..<q]) }
        return (path, query, fragment)
    }

    private func encodeRelativeReference(_ path: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let leadingSlash = path.hasPrefix("/")
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            let s = String(segment)
            if s == "." || s == ".." { return s }
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        let encoded = parts.joined(separator: "/")
        return leadingSlash && !encoded.hasPrefix("/") ? "/" + encoded : encoded
    }

    private func isExternalScheme(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let scheme = value[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }

    private func replace(pattern: String, in text: String, transform: (NSTextCheckingResult, String) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let replacement = transform(match, text), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private func detectTextEncoding(_ data: Data) -> String.Encoding {
        if data.starts(with: [0xFF,0xFE]) { return .utf16LittleEndian }
        if data.starts(with: [0xFE,0xFF]) { return .utf16BigEndian }
        return .utf8
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        let c = candidate.standardizedFileURL.path
        let r = root.standardizedFileURL.path
        return c == r || c.hasPrefix(r + "/")
    }

    enum ResourceError:LocalizedError{case invalidArchive;var errorDescription:String?{"EPUB 压缩包无效"}}
}
