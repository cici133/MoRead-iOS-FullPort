import Foundation
import SwiftUI

@MainActor
final class LibraryStore: ObservableObject {
    @Published var books: [Book] = []
    @Published var aiSettings = AISettings()
    @Published var isReady = false
    @Published var lastError: String?

    private let repository = LibraryRepository.shared
    private let settingsURL: URL

    init() {
        let root = (try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory
        settingsURL = root.appendingPathComponent("ios-compat-settings.json")
        loadLegacySettings()
        Task { await bootstrap() }
    }

    func bootstrap() async {
        do {
            try await MoReadDatabase.shared.openIfNeeded()
            try await refresh()
            var generated=false
            for book in books where book.coverPath == nil || book.coverPath?.isEmpty == true {
                if (try? await TextCoverGenerator.shared.ensureCover(for:book)) != nil { generated=true }
            }
            if generated { try await refresh() }
            isReady = true
        } catch { lastError = error.localizedDescription; isReady = true }
    }

    func refresh() async throws { books = try await repository.listBooks() }

    func importBook(_ draft: ImportedBook) async throws {
        _ = try await repository.importBook(draft)
        try await refresh()
    }

    func remove(at offsets: IndexSet, permanently: Bool = false) {
        let ids = offsets.compactMap { books.indices.contains($0) ? books[$0].id : nil }
        Task {
            do {
                for id in ids {
                    if permanently { try await repository.permanentlyDelete(bookId: id) }
                    else { try await repository.softRemove(bookId: id) }
                }
                try await refresh()
            } catch { lastError = error.localizedDescription }
        }
    }

    func chapters(bookId: Int64) async throws -> [Chapter] { try await repository.chapters(bookId: bookId) }
    func chapterText(_ chapter: Chapter) async throws -> String { try await repository.chapterText(chapter) }
    func book(id: Int64) async throws -> Book? { try await repository.book(id: id) }

    func updateProgress(bookId: Int64, chapterIndex: Int, charOffset: Int, reachedEnd: Bool = false) async throws {
        try await repository.updateProgress(bookId: bookId, chapterIndex: chapterIndex, charOffset: charOffset, reachedEnd: reachedEnd)
        try await refresh()
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(aiSettings).write(to: settingsURL, options: .atomic)
        } catch { lastError = error.localizedDescription }
    }

    private func loadLegacySettings() {
        guard let data = try? Data(contentsOf: settingsURL), let value = try? JSONDecoder().decode(AISettings.self, from: data) else { return }
        aiSettings = value
    }
}
