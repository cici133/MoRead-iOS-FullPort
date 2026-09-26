import Foundation

struct BookImportService {
    static func importBook(url: URL) async throws -> ImportedBook {
        let ext = url.pathExtension.lowercased()
        return try await Task.detached(priority: .userInitiated) {
            if ext == "epub" { return try EPUBImporter.importEPUB(url: url) }
            return try TextImporter.importTXT(url: url)
        }.value
    }
}
