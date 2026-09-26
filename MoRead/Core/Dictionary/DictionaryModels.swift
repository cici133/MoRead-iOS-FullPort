import Foundation

struct LocalDictionary: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var resourceCount: Int
    var enabled: Bool
}

struct DictionaryDefinition: Identifiable, Hashable, Sendable {
    var id: String { dictionaryId + ":" + title }
    let dictionaryId: String
    let title: String
    let html: String
}

struct VocabularyEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String { word.lowercased() }
    let word: String
    var phonetic: String
    var shortGloss: String
    var definitionMarkdown: String
    var sourceDictionaryId: String?
    var bookId: Int64?
    var chapterIndex: Int?
    var charOffset: Int?
    var learned: Bool
    var createdAt: Int64
    var updatedAt: Int64
}

struct AiDictionaryEntry: Codable, Hashable, Sendable {
    var label: String = ""
    var phonetic: String = ""
    var gloss: String = ""
    var markdown: String = ""

    static func parse(_ raw: String) -> AiDictionaryEntry {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = clean.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func string(_ names: [String]) -> String {
                for name in names {
                    if let value = object[name] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return ""
            }
            return .init(
                label: string(["label", "annotation", "cn", "中文标注"]),
                phonetic: string(["phonetic", "ipa", "音标"]),
                gloss: string(["gloss", "short_gloss", "短释义"]),
                markdown: string(["markdown", "definition", "meaning", "释义"])
            )
        }
        return .init(markdown: clean)
    }
}

struct ParagraphTranslationRecord: Codable, Hashable, Sendable {
    let bookId: Int64
    let chapterIndex: Int
    let start: Int
    let end: Int
    let sourceHash: String
    var translatedText: String
    var modelKey: String
    var createdAt: Int64
    /// Additive optional keeps translation caches written by older iOS builds decodable.
    var hidden: Bool? = nil
    var isHidden: Bool { hidden ?? false }
}
