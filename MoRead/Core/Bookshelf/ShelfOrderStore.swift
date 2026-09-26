import Foundation

@MainActor
final class ShelfOrderStore: ObservableObject {
    static let shared = ShelfOrderStore()
    @Published private(set) var order: [Int64]
    @Published private(set) var readAnchor: Int64
    @Published var readingOrderAffectsShelf: Bool {
        didSet { UserDefaults.standard.set(readingOrderAffectsShelf, forKey: Keys.affects) }
    }

    private init() {
        let defaults = UserDefaults.standard
        order = Self.decode(defaults.string(forKey: Keys.order) ?? "")
        readAnchor = Int64(defaults.string(forKey: Keys.anchor) ?? "0") ?? 0
        readingOrderAffectsShelf = defaults.object(forKey: Keys.affects) as? Bool ?? true
    }

    func ordered(_ books: [Book]) -> [Book] {
        let fallback = books.sorted {
            if ($0.pinnedAt > 0) != ($1.pinnedAt > 0) { return $0.pinnedAt > 0 }
            if $0.pinnedAt > 0, $0.pinnedAt != $1.pinnedAt { return $0.pinnedAt > $1.pinnedAt }
            if readingOrderAffectsShelf, $0.lastReadAt != $1.lastReadAt { return $0.lastReadAt > $1.lastReadAt }
            return $0.importedAt > $1.importedAt
        }
        guard !order.isEmpty else { return fallback }
        let byId = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        let saved = Set(order)
        let base = fallback.filter { !saved.contains($0.id) } + order.compactMap { byId[$0] }
        let pinned = base.filter { $0.pinnedAt > 0 }
        let unpinned = base.filter { $0.pinnedAt == 0 }
        guard readingOrderAffectsShelf else { return pinned + unpinned }
        let newlyRead = unpinned.filter { $0.lastReadAt > readAnchor }.sorted { $0.lastReadAt > $1.lastReadAt }
        let moved = Set(newlyRead.map(\.id))
        return pinned + newlyRead + unpinned.filter { !moved.contains($0.id) }
    }

    func saveVisibleOrder(_ visibleIds: [Int64], allBooks: [Book]) {
        let allIds = ordered(allBooks).map(\.id)
        let existing = Set(allIds)
        let cleanVisible = visibleIds.filter { existing.contains($0) }.reduce(into: [Int64]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        let visibleSet = Set(cleanVisible)
        var iterator = cleanVisible.makeIterator()
        order = allIds.map { id in visibleSet.contains(id) ? (iterator.next() ?? id) : id }
        readAnchor = allBooks.map(\.lastReadAt).max() ?? 0
        persist()
    }

    func move(bookId: Int64, before targetId: Int64, allBooks: [Book]) {
        var ids = ordered(allBooks).map(\.id)
        guard let source = ids.firstIndex(of: bookId), let target = ids.firstIndex(of: targetId), bookId != targetId else { return }
        let movingBook = allBooks.first { $0.id == bookId }
        let targetBook = allBooks.first { $0.id == targetId }
        guard ((movingBook?.pinnedAt ?? 0) > 0) == ((targetBook?.pinnedAt ?? 0) > 0) else { return }
        let value = ids.remove(at: source)
        let adjusted = ids.firstIndex(of: targetId) ?? target
        ids.insert(value, at: adjusted)
        order = ids
        readAnchor = allBooks.map(\.lastReadAt).max() ?? 0
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(order.map(String.init).joined(separator: ","), forKey: Keys.order)
        UserDefaults.standard.set(String(readAnchor), forKey: Keys.anchor)
    }

    private static func decode(_ raw: String) -> [Int64] {
        raw.split(separator: ",").compactMap { Int64($0) }
    }

    enum Keys {
        static let order = "shelf.book.order"
        static let anchor = "shelf.book.order.read.anchor"
        static let affects = "shelf.reading.order.affects"
    }
}
