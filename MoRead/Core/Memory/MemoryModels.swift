import Foundation

struct LongTermMemory: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var personaId: Int64
    var bookId: Int64?
    var maskId: Int64
    var summary: String
    var sourceConversationId: Int64
    var sourceThroughMessageId: Int64
    var embedding: [Float]?
    var createdAt: Int64
    var updatedAt: Int64
}

enum MemoryOperation: Equatable, Sendable {
    case add(String)
    case update(UUID, String)
    case delete(UUID)

    static let maxOperations = 8
    static let maxSummaryChars = 500

    static func parse(_ raw: String) -> [MemoryOperation] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        let candidate: String
        if let a = trimmed.firstIndex(of: "["), let b = trimmed.lastIndex(of: "]"), a <= b { candidate = String(trimmed[a...b]) }
        else { candidate = trimmed }
        guard let data = candidate.data(using: .utf8), let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let action = (row["action"] as? String)?.uppercased() ?? ""
            let summary = String(((row["summary"] as? String) ?? "").prefix(maxSummaryChars)).trimmingCharacters(in: .whitespacesAndNewlines)
            let id = (row["id"] as? String).flatMap(UUID.init(uuidString:))
            switch action {
            case "ADD": return summary.isEmpty ? nil : .add(summary)
            case "UPDATE": return id.map { summary.isEmpty ? .delete($0) : .update($0, summary) } ?? (summary.isEmpty ? nil : .add(summary))
            case "DELETE": return id.map(MemoryOperation.delete)
            default: return nil
            }
        }.prefix(maxOperations).map { $0 }
    }
}

struct RollingSummaryWork: Sendable {
    let messages: [AIStoredMessage]
    let throughMessageId: Int64
}

enum RollingSummaryPlanner {
    static let windowMessages = 20, minBatch = 6, maxBatch = 40, maxSummaryChars = 600
    static func plan(messages:[AIStoredMessage],consolidatedThrough:Int64,summarizedThrough:Int64)->RollingSummaryWork?{
        let inContext=messages.filter{$0.id>consolidatedThrough};guard inContext.count>windowMessages else{return nil}
        let pending=inContext.dropLast(windowMessages).filter{$0.id>summarizedThrough && !$0.content.isEmpty && ($0.role=="user"||$0.role=="assistant")}
        guard pending.count>=minBatch else{return nil};let selected=Array(pending.prefix(maxBatch));return .init(messages:selected,throughMessageId:selected.last!.id)
    }
    static func transcript(_ work:RollingSummaryWork)->String{var s="";for m in work.messages{let prefix=m.role=="user" ? "用户：":"我：";s += prefix + String(m.content.prefix(1200)) + "\n";if s.count>=12000{break}};return String(s.prefix(12000))}
}
