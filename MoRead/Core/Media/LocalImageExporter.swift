import Foundation
import Photos

actor LocalImageExporter {
    static let shared = LocalImageExporter()

    func saveToPhotos(path: String) async throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ExportError.missing }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.denied }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
            }) { ok, error in
                if let error { continuation.resume(throwing: error) }
                else if ok { continuation.resume(returning: ()) }
                else { continuation.resume(throwing: ExportError.failed) }
            }
        }
    }

    func setBookCover(book: Book, imagePath: String) async throws -> String {
        let source = URL(fileURLWithPath: imagePath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw ExportError.missing }
        try FileManager.default.createDirectory(at: AppPaths.covers, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let target = AppPaths.covers.appendingPathComponent("book-\(book.id)-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: target)
        do {
            try await BookshelfRepository.shared.updateMetadata(bookId: book.id, title: book.title, author: book.author, coverPath: target.path)
            if let old = book.coverPath, old != target.path, old.hasPrefix(AppPaths.covers.path + "/") { try? FileManager.default.removeItem(atPath: old) }
            return target.path
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    enum ExportError: LocalizedError {
        case missing, denied, failed
        var errorDescription: String? {
            switch self {
            case .missing: "图片文件不存在"
            case .denied: "没有保存到照片的权限，请到系统设置允许添加照片"
            case .failed: "保存图片失败"
            }
        }
    }
}
