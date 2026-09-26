import Foundation

enum AppPaths {
    private static var root: URL { (try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MoRead", isDirectory: true) }
    static var booksRoot: URL { root.appendingPathComponent("books", isDirectory: true) }
    static var bookTextRoot: URL { root.appendingPathComponent("book-text", isDirectory: true) }
    static var bookMediaRoot: URL { root.appendingPathComponent("book-media", isDirectory: true) }
    static var bookLayoutRoot: URL { root.appendingPathComponent("book-layout", isDirectory: true) }
    static var bookIndexRoot: URL { root.appendingPathComponent("book-index", isDirectory: true) }
    static var speechCache: URL { root.appendingPathComponent("speech-cache", isDirectory: true) }
    static var illustrations: URL { root.appendingPathComponent("illustrations", isDirectory: true) }
    static var attachments: URL { root.appendingPathComponent("attachments", isDirectory: true) }
    static var covers: URL { root.appendingPathComponent("covers", isDirectory: true) }
    static var avatars: URL { root.appendingPathComponent("avatars", isDirectory: true) }
    static var imageVibes: URL { root.appendingPathComponent("image-vibes", isDirectory: true) }
    static var imageLibrary: URL { root.appendingPathComponent("image-library", isDirectory: true) }
    static var readerCustom: URL { root.appendingPathComponent("reader-custom", isDirectory: true) }
    static var exports: URL { root.appendingPathComponent("exports", isDirectory: true) }
    static var backups: URL { root.appendingPathComponent("backups", isDirectory: true) }
    static func speechCache(bookId: Int64?) -> URL { speechCache.appendingPathComponent(bookId.map(String.init) ?? "global", isDirectory: true) }
}
