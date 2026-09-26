import Foundation
import UIKit

actor TextCoverGenerator {
    static let shared = TextCoverGenerator()

    func ensureCover(for book: Book) async throws -> String {
        if let path = book.coverPath, FileManager.default.fileExists(atPath: path) { return path }
        let root = try MoReadDatabase.applicationDirectory().appendingPathComponent("covers", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("generated-\(book.id).png")
        if FileManager.default.fileExists(atPath: url.path) {
            try await BookshelfRepository.shared.setCoverPath(bookId: book.id, path: url.path)
            return url.path
        }
        let image = await MainActor.run { Self.render(title: book.title, author: book.author, seed: book.id) }
        guard let data = image.pngData(), !data.isEmpty else { throw CoverError.renderFailed }
        try data.write(to: url, options: .atomic)
        try await BookshelfRepository.shared.setCoverPath(bookId: book.id, path: url.path)
        return url.path
    }

    @MainActor private static func render(title: String, author: String, seed: Int64) -> UIImage {
        let size = CGSize(width: 720, height: 1080)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let palette: [(UIColor, UIColor)] = [
                (.systemBackground, .label),
                (UIColor(red:0.92,green:0.89,blue:0.82,alpha:1), UIColor(red:0.19,green:0.17,blue:0.15,alpha:1)),
                (UIColor(red:0.83,green:0.88,blue:0.86,alpha:1), UIColor(red:0.13,green:0.22,blue:0.20,alpha:1)),
                (UIColor(red:0.87,green:0.85,blue:0.91,alpha:1), UIColor(red:0.20,green:0.17,blue:0.26,alpha:1))
            ]
            let pair = palette[Int(abs(seed) % Int64(palette.count))]
            pair.0.setFill(); ctx.fill(CGRect(origin:.zero,size:size))
            let inset = CGRect(x:54,y:54,width:size.width-108,height:size.height-108)
            pair.1.withAlphaComponent(0.15).setStroke()
            let path = UIBezierPath(roundedRect: inset, cornerRadius: 26); path.lineWidth = 2; path.stroke()

            let cleanTitle = title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "未命名" : title.trimmingCharacters(in:.whitespacesAndNewlines)
            let chars = Array(cleanTitle.prefix(28))
            let perColumn = 7
            let columns = stride(from:0,to:chars.count,by:perColumn).map { Array(chars[$0..<min(chars.count,$0+perColumn)]) }
            let font = UIFont.systemFont(ofSize:70,weight:.semibold)
            let attrs: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:pair.1]
            let columnWidth:CGFloat = 92, lineHeight:CGFloat = 88
            let startX = size.width - 125
            let startY:CGFloat = 155
            for (columnIndex,column) in columns.prefix(5).enumerated() {
                let x = startX - CGFloat(columnIndex)*columnWidth
                for (row,ch) in column.enumerated() {
                    String(ch).draw(at:CGPoint(x:x,y:startY+CGFloat(row)*lineHeight),withAttributes:attrs)
                }
            }
            if !author.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                let authorText = String(author.trimmingCharacters(in:.whitespacesAndNewlines).prefix(22))
                let aAttrs:[NSAttributedString.Key:Any] = [.font:UIFont.systemFont(ofSize:30,weight:.regular),.foregroundColor:pair.1.withAlphaComponent(0.72)]
                authorText.draw(in:CGRect(x:80,y:size.height-155,width:size.width-160,height:44),withAttributes:aAttrs)
            }
            let markAttrs:[NSAttributedString.Key:Any] = [.font:UIFont.systemFont(ofSize:22,weight:.medium),.foregroundColor:pair.1.withAlphaComponent(0.45)]
            "墨知 MoRead".draw(at:CGPoint(x:80,y:size.height-92),withAttributes:markAttrs)
        }
    }

    enum CoverError: LocalizedError { case renderFailed; var errorDescription:String? { "文字封面生成失败" } }
}
