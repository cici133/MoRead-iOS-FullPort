import Foundation

struct LibraryOrganizationTag: Codable, Hashable, Sendable, Identifiable {
    var id: Int64
    var name: String
}

struct LibraryOrganizationChange: Codable, Hashable, Sendable, Identifiable {
    var bookId: Int64
    var title: String
    var beforeTags: [LibraryOrganizationTag]
    var beforeGroupId: Int64?
    var beforeGroupName: String
    var beforeGroupParentId: Int64?
    var addTags: [String]
    var removeTags: [String]
    var groupName: String?
    var existingAddTags: [LibraryOrganizationTag]
    var targetGroupId: Int64?
    var id: Int64 { bookId }
}

struct LibraryOrganizationPlan: Codable, Hashable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable { case pending = "PENDING", applied = "APPLIED", cancelled = "CANCELLED" }
    var id: String
    var changes: [LibraryOrganizationChange]
    var status: Status = .pending
}

struct LibraryOrganizationMessage: Identifiable, Hashable, Sendable {
    var messageId: Int64
    var plan: LibraryOrganizationPlan
    var id: Int64 { messageId }
}

struct LibraryOrganizationRequest: Hashable, Sendable {
    var bookId: Int64
    var addTags: [String]
    var removeTags: [String]
    var groupName: String?
}

enum LibraryOrganizationPlans {
    static let prefix = "MO_READ_LIBRARY_PLAN\n"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encode(_ plan: LibraryOrganizationPlan) throws -> String {
        try validate(plan)
        let data = try encoder.encode(plan)
        guard let body = String(data: data, encoding: .utf8) else { throw LibraryOrganizationError.invalid("方案编码失败") }
        let output = prefix + body
        guard output.utf8.count <= 48_000 else { throw LibraryOrganizationError.invalid("方案过大，请减少书籍") }
        return output
    }

    static func decode(_ raw: String) -> LibraryOrganizationPlan? {
        guard raw.hasPrefix(prefix), raw.utf8.count <= 48_000,
              let data = raw.dropFirst(prefix.count).data(using: .utf8),
              let plan = try? decoder.decode(LibraryOrganizationPlan.self, from: data),
              (try? validate(plan)) != nil else { return nil }
        return plan
    }

    static func requests(arguments: [String: Any]) throws -> [LibraryOrganizationRequest] {
        guard let rows = arguments["changes"] as? [[String: Any]], (1...20).contains(rows.count) else {
            throw LibraryOrganizationError.invalid("每份方案需要 1–20 本书")
        }
        let result = try rows.map { row -> LibraryOrganizationRequest in
            guard let id = int64(row["book_id"]), id > 0 else { throw LibraryOrganizationError.invalid("书籍编号无效") }
            func names(_ key: String) throws -> [String] {
                guard let raw = row[key] else { return [] }
                guard let values = raw as? [Any], values.count <= 8 else { throw LibraryOrganizationError.invalid("每本书一次最多修改 8 个标签") }
                var output: [String] = []
                for value in values {
                    guard let text = value as? String else { throw LibraryOrganizationError.invalid("标签名称无效") }
                    let name = normalize(text, max: 24)
                    guard !name.isEmpty else { throw LibraryOrganizationError.invalid("标签名称不能为空") }
                    if !output.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { output.append(name) }
                }
                return output
            }
            let add = try names("add_tags")
            let remove = try names("remove_tags")
            guard add.allSatisfy({ a in !remove.contains(where: { $0.caseInsensitiveCompare(a) == .orderedSame }) }) else {
                throw LibraryOrganizationError.invalid("不能同时添加和移除同一标签")
            }
            let group: String?
            if let raw = row["group_name"] {
                guard let text = raw as? String else { throw LibraryOrganizationError.invalid("分组名称无效") }
                let clean = normalize(text, max: 30)
                guard !clean.isEmpty else { throw LibraryOrganizationError.invalid("分组名称无效") }
                group = clean
            } else { group = nil }
            guard !add.isEmpty || !remove.isEmpty || group != nil else { throw LibraryOrganizationError.invalid("方案没有变更") }
            return .init(bookId: id, addTags: add, removeTags: remove, groupName: group)
        }
        guard Set(result.map(\.bookId)).count == result.count else { throw LibraryOrganizationError.invalid("同一本书请合并为一条变更") }
        return result
    }

    static func validate(_ plan: LibraryOrganizationPlan) throws {
        guard !plan.id.isEmpty, plan.id.count <= 80, (1...20).contains(plan.changes.count) else { throw LibraryOrganizationError.invalid("方案格式无效") }
        guard Set(plan.changes.map(\.bookId)).count == plan.changes.count else { throw LibraryOrganizationError.invalid("方案含重复书籍") }
        for change in plan.changes {
            guard change.bookId > 0, !change.title.isEmpty, change.title.count <= 120 else { throw LibraryOrganizationError.invalid("方案书籍信息无效") }
            guard change.addTags.count <= 8, change.removeTags.count <= 8 else { throw LibraryOrganizationError.invalid("标签数量无效") }
            guard change.beforeTags.count <= 256, Set(change.beforeTags.map(\.id)).count == change.beforeTags.count else { throw LibraryOrganizationError.invalid("标签快照无效") }
        }
    }

    private static func normalize(_ raw: String, max: Int) -> String {
        let compact = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(compact.prefix(max)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func int64(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }
}

actor LibraryOrganizationCoordinator {
    static let shared = LibraryOrganizationCoordinator()
    private let library = LibraryRepository.shared
    private let shelf = BookshelfRepository.shared
    private let chats = AIConversationRepository.shared

    func preview(_ requests: [LibraryOrganizationRequest]) async throws -> LibraryOrganizationPlan {
        guard (1...20).contains(requests.count), Set(requests.map(\.bookId)).count == requests.count else {
            throw LibraryOrganizationError.invalid("整理方案书籍数量无效")
        }
        let allGroups = try await shelf.groups()
        let allTags = try await shelf.tags()
        var changes: [LibraryOrganizationChange] = []
        for request in requests {
            guard let book = try await library.book(id: request.bookId), book.removedAt == 0 else { throw LibraryOrganizationError.invalid("书籍已被移除") }
            let beforeTags = try await shelf.tags(bookId: book.id)
            let beforeGroup = book.groupId.flatMap { id in allGroups.first { $0.id == id } }
            for remove in request.removeTags where !beforeTags.contains(where: { same($0.name, remove) }) {
                throw LibraryOrganizationError.invalid("《\(book.title.prefix(24))》没有标签“\(remove)”")
            }
            let add = request.addTags.filter { name in !beforeTags.contains(where: { same($0.name, name) }) }
            let groupName = request.groupName.flatMap { desired -> String? in
                if beforeGroup?.parentId == nil, beforeGroup.map({ same($0.name, desired) }) == true { return nil }
                return desired
            }
            if add.isEmpty && request.removeTags.isEmpty && groupName == nil { continue }
            let existingAddTags = add.compactMap { name in allTags.first(where: { same($0.name, name) }).map { LibraryOrganizationTag(id: $0.id, name: $0.name) } }
            let targetGroup = groupName.flatMap { desired in allGroups.first(where: { $0.parentId == nil && same($0.name, desired) }) }
            changes.append(.init(bookId: book.id, title: String(book.title.prefix(120)), beforeTags: beforeTags.map { .init(id: $0.id, name: $0.name) }, beforeGroupId: book.groupId, beforeGroupName: beforeGroup?.name ?? "", beforeGroupParentId: beforeGroup?.parentId, addTags: add, removeTags: request.removeTags, groupName: groupName, existingAddTags: existingAddTags, targetGroupId: targetGroup?.id))
        }
        guard !changes.isEmpty else { throw LibraryOrganizationError.invalid("书架无需调整") }
        let plan = LibraryOrganizationPlan(id: UUID().uuidString, changes: changes)
        _ = try LibraryOrganizationPlans.encode(plan)
        return plan
    }

    func confirm(messageId: Int64, apply shouldApply: Bool) async throws -> Int {
        guard let message = try await chats.message(id: messageId), message.role == "tool",
              let plan = LibraryOrganizationPlans.decode(message.content), plan.status == .pending,
              let conversation = try await chats.conversation(id: message.conversationId), conversation.bookId == nil, conversation.type == "LIBRARY" else {
            throw LibraryOrganizationError.invalid("这份方案已不存在或已处理")
        }
        if shouldApply {
            try await revalidate(plan)
            for change in plan.changes { try await apply(change) }
        }
        var updated = plan
        updated.status = shouldApply ? .applied : .cancelled
        try await chats.updateMessageContent(messageId: messageId, content: LibraryOrganizationPlans.encode(updated))
        return shouldApply ? plan.changes.count : 0
    }

    private func revalidate(_ plan: LibraryOrganizationPlan) async throws {
        let groups = try await shelf.groups()
        let tags = try await shelf.tags()
        for change in plan.changes {
            guard let book = try await library.book(id: change.bookId), book.removedAt == 0, String(book.title.prefix(120)) == change.title, book.groupId == change.beforeGroupId else {
                throw LibraryOrganizationError.changed
            }
            let group = book.groupId.flatMap { id in groups.first { $0.id == id } }
            guard (group?.name ?? "") == change.beforeGroupName, group?.parentId == change.beforeGroupParentId else { throw LibraryOrganizationError.changed }
            let currentTags = try await shelf.tags(bookId: book.id).map { LibraryOrganizationTag(id: $0.id, name: $0.name) }
            guard Set(currentTags) == Set(change.beforeTags) else { throw LibraryOrganizationError.changed }
            for expected in change.existingAddTags {
                guard let current = tags.first(where: { same($0.name, expected.name) }), current.id == expected.id else { throw LibraryOrganizationError.changed }
            }
            if let targetId = change.targetGroupId {
                guard let target = groups.first(where: { $0.id == targetId }), target.parentId == nil, target.name == change.groupName else { throw LibraryOrganizationError.changed }
            }
        }
    }

    private func apply(_ change: LibraryOrganizationChange) async throws {
        var tagIds = Set((try await shelf.tags(bookId: change.bookId)).map(\.id))
        for remove in change.removeTags {
            if let row = try await shelf.tags(bookId: change.bookId).first(where: { same($0.name, remove) }) { tagIds.remove(row.id) }
        }
        for name in change.addTags {
            let id: Int64
            if let existing = (try await shelf.tags()).first(where: { same($0.name, name) }) { id = existing.id }
            else { id = try await shelf.createTag(name: name) }
            tagIds.insert(id)
        }
        try await shelf.setTags(bookId: change.bookId, tagIds: Array(tagIds))
        if let name = change.groupName {
            let groupId: Int64
            if let target = change.targetGroupId { groupId = target }
            else if let existing = (try await shelf.groups()).first(where: { $0.parentId == nil && same($0.name, name) }) { groupId = existing.id }
            else { groupId = try await shelf.createGroup(name: name, parentId: nil) }
            try await shelf.setGroup(bookId: change.bookId, groupId: groupId)
        }
    }

    private func same(_ a: String, _ b: String) -> Bool { a.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
}

enum LibraryOrganizationError: LocalizedError {
    case invalid(String), changed
    var errorDescription: String? { switch self { case .invalid(let text): text; case .changed: "书架已发生变化，请重新生成整理方案" } }
}
