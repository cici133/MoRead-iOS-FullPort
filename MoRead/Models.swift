import Foundation

struct Chapter: Identifiable, Hashable, Sendable {
    let id: Int64
    let bookId: Int64
    let chapterIndex: Int
    var title: String
    var href: String
    var charCount: Int
    var textByteOffset: Int64
    var textByteLength: Int
}

struct Book: Identifiable, Hashable, Sendable {
    let id: Int64
    var title: String
    var author: String
    var coverPath: String?
    var epubPath: String
    var sourceType: String
    var importedAt: Int64
    var totalChapters: Int
    var lastReadLocator: String?
    var lastReadChapterIndex: Int
    var lastReadCharOffset: Int
    var maxReachedChapterIndex: Int
    var maxReachedCharOffset: Int
    var lastReadAt: Int64
    var textVersion: Int
    var tags: String
    var metadataEdited: Bool
    var manualReadState: String?
    var reachedEnd: Bool
    var pinnedAt: Int64
    var groupId: Int64?
    var collectionId: Int64?
    var collectionOrder: Int
    var removedAt: Int64
    var totalChars: Int64 = 0
    var charsBeforeLastChapter: Int64 = 0

    var progress: Double {
        BookReadProgress.fraction(
            .init(lastReadAt: lastReadAt, reachedEnd: reachedEnd, totalChapters: totalChapters,
                  lastReadChapterIndex: lastReadChapterIndex, lastReadCharOffset: lastReadCharOffset),
            span: .init(charsBeforeChapter: charsBeforeLastChapter, totalChars: totalChars)
        )
    }
    var progressPercent: Int { BookReadProgress.percent(progress) }
    var format: String { sourceType.uppercased() }
}

struct ImportedChapter: Sendable {
    var title: String
    var href: String = ""
    var text: String
}

struct ImportedBook: Sendable {
    var title: String
    var author: String = ""
    var sourceType: String
    var sourceURL: URL?
    var chapters: [ImportedChapter]
    var toc: [ImportedTOCEntry] = []
    var coverData: Data? = nil
    var coverFileExtension: String? = nil
}

struct ImportedTOCEntry: Sendable {
    var orderIndex: Int
    var title: String
    var href: String
    var depth: Int
    var parentOrderIndex: Int?
    var chapterIndex: Int?
    var hasChildren: Bool
}

struct AIMessage: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var role: String
    var content: String
}

/// Compatibility view for the old one-provider UI. Full provider/model configuration is stored in
/// ai_providers, ai_models and model_assignments through AIProviderRepository.
struct AISettings: Codable, Equatable, Sendable {
    var baseURL = "https://api.openai.com/v1"
    var model = "gpt-4.1-mini"
}
