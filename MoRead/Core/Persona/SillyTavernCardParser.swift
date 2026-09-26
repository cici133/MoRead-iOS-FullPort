import Foundation

struct ImportedPersonaCard: Sendable {
    var name: String
    var subtitle: String
    var personality: String
    var speakingStyle: String
    var greeting: String
    var exampleDialogs: [PersonaExampleDialog]
    var worldBook: [PersonaLoreEntry]
    var avatarPNG: Data?
}

enum SillyTavernCardParser {
    private static let signature = Data([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A])

    static func parse(_ bytes: Data) -> ImportedPersonaCard? {
        do {
            let isPNG = bytes.count > 8 && bytes.prefix(8) == signature
            let payload: Data
            if isPNG {
                guard let encoded = extractTextPayload(bytes), let decoded = Data(base64Encoded: encoded.filter { !$0.isWhitespace }) else { return nil }
                payload = decoded
            } else { payload = bytes }
            guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
            let data = (root["data"] as? [String: Any]) ?? root
            guard let rawName = data["name"] as? String else { return nil }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            func substitute(_ text: String) -> String {
                text.replacingOccurrences(of: "{{char}}", with: name, options: .caseInsensitive)
                    .replacingOccurrences(of: "{{user}}", with: "用户", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let description = substitute(data["description"] as? String ?? "")
            let traits = substitute(data["personality"] as? String ?? "")
            let scenario = substitute(data["scenario"] as? String ?? "")
            var personality = description
            if !traits.isEmpty { personality += (personality.isEmpty ? "" : "\n\n") + "性格特质：\(traits)" }
            if !scenario.isEmpty { personality += (personality.isEmpty ? "" : "\n\n") + "场景设定：\(scenario)" }
            let tags = (data["tags"] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
            let creator = (data["creator"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let subtitle = !tags.isEmpty ? tags.prefix(3).joined(separator: " · ") : (creator.isEmpty ? "" : "by \(creator)")
            let world = parseWorldBook(data["character_book"], substitute: substitute)
            let examples = parseExamples(data["mes_example"] as? String ?? "", name: name)
            return .init(name: name, subtitle: subtitle, personality: personality,
                         speakingStyle: substitute(data["creator_notes"] as? String ?? ""),
                         greeting: substitute(data["first_mes"] as? String ?? ""), exampleDialogs: examples,
                         worldBook: world, avatarPNG: isPNG ? bytes : nil)
        } catch { return nil }
    }

    private static func extractTextPayload(_ data: Data) -> String? {
        let bytes = [UInt8](data); var offset = 8; var chara: String?; var ccv3: String?
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset+1]) << 16 | Int(bytes[offset+2]) << 8 | Int(bytes[offset+3])
            let start = offset + 8
            guard length >= 0, start <= bytes.count, length <= bytes.count - start else { break }
            let type = String(bytes: bytes[(offset+4)..<(offset+8)], encoding: .ascii) ?? ""
            if type == "tEXt" {
                let chunk = Array(bytes[start..<(start+length)])
                if let zero = chunk.firstIndex(of: 0), zero > 0 {
                    let key = String(bytes: chunk[..<zero], encoding: .isoLatin1)?.lowercased() ?? ""
                    let value = String(bytes: chunk[(zero+1)...], encoding: .isoLatin1) ?? ""
                    if key == "ccv3" { ccv3 = value }
                    if key == "chara" { chara = value }
                }
            }
            if type == "IEND" { break }
            offset = start + length + 4
        }
        return ccv3 ?? chara
    }

    private static func parseWorldBook(_ raw: Any?, substitute: (String) -> String) -> [PersonaLoreEntry] {
        guard let book = raw as? [String: Any], let entries = book["entries"] as? [Any] else { return [] }
        struct Indexed { var order: Double; var index: Int; var value: PersonaLoreEntry }
        return entries.enumerated().compactMap { index, element -> Indexed? in
            guard let e = element as? [String: Any] else { return nil }
            let content = substitute(e["content"] as? String ?? "")
            guard !content.isEmpty else { return nil }
            let enabled = e["enabled"] as? Bool ?? true
            let keys = (e["keys"] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
            let constant = (e["constant"] as? Bool ?? false) || keys.isEmpty
            let name = substitute(e["comment"] as? String ?? "").isEmpty ? (keys.first ?? "") : substitute(e["comment"] as? String ?? "")
            let order = (e["insertion_order"] as? NSNumber)?.doubleValue ?? 0
            return .init(order: order, index: index, value: .init(name: name, content: content, enabled: enabled, constant: constant, keys: keys))
        }.sorted { $0.order == $1.order ? $0.index < $1.index : $0.order < $1.order }.map(\.value)
    }

    static func parseExamples(_ raw: String, name: String) -> [PersonaExampleDialog] {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var output: [PersonaExampleDialog] = []
        let blocks = raw.replacingOccurrences(of: "<start>", with: "<START>", options: .caseInsensitive).components(separatedBy: "<START>")
        for block in blocks {
            var user: String?; var assistant: String?
            func flush() {
                let u = user?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let a = assistant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !u.isEmpty && !a.isEmpty { output.append(.init(user: substitute(u,name:name), assistant: substitute(a,name:name))) }
                user=nil; assistant=nil
            }
            for rawLine in block.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines); if line.isEmpty { continue }
                let lower = line.lowercased()
                if lower.hasPrefix("{{user}}:") || lower.hasPrefix("{{user}}：") {
                    if assistant != nil { flush() }; user = String(line.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if lower.hasPrefix("{{char}}:") || lower.hasPrefix("{{char}}：") {
                    guard user != nil else { continue }; assistant = String(line.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if assistant != nil { assistant! += "\n" + line }
                else if user != nil { user! += "\n" + line }
            }
            flush()
        }
        return output
    }

    private static func substitute(_ text: String, name: String) -> String {
        text.replacingOccurrences(of:"{{char}}",with:name,options:.caseInsensitive)
            .replacingOccurrences(of:"{{user}}",with:"用户",options:.caseInsensitive)
    }
}
