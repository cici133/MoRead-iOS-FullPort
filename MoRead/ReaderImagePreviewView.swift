import SwiftUI
import UIKit

struct ReaderImagePreviewItem: Identifiable {
    let id = UUID()
    let url: URL
    let book: Book
}

struct ReaderImagePreviewView: View {
    let item: ReaderImagePreviewItem
    @Environment(\.dismiss) private var dismiss
    @State private var quarterTurns = 0
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1
    @State private var lastOffset: CGSize = .zero
    @State private var exportURL: URL?
    @State private var message: String?

    private var image: UIImage? { UIImage(contentsOfFile: item.url.path) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .rotationEffect(.degrees(Double(quarterTurns * 90)))
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(MagnifyGesture().onChanged { value in scale = min(6, max(0.5, lastScale * value.magnification)) }.onEnded { _ in lastScale = scale })
                        .simultaneousGesture(DragGesture().onChanged { value in offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height) }.onEnded { _ in lastOffset = offset })
                        .onTapGesture(count: 2) { withAnimation { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero } }
                } else {
                    ContentUnavailableView("无法预览这张图片", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.white)
                }
            }
            .navigationTitle(item.url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button("关闭"){dismiss()}}
                ToolbarItemGroup(placement:.topBarTrailing){
                    Button { quarterTurns = (quarterTurns + 3) % 4; updateExport() } label:{Image(systemName:"rotate.left")}
                    Button { quarterTurns = (quarterTurns + 1) % 4; updateExport() } label:{Image(systemName:"rotate.right")}
                    Menu {
                        Button { Task { await addToImageLibrary() } } label: { Label("加入图片库", systemImage: "photo.on.rectangle") }
                        Button { Task { await setAsCover() } } label: { Label("设为本书封面", systemImage: "book.closed") }
                        Button { Task { await savePhoto() } } label:{ Label("保存到照片", systemImage:"photo.badge.arrow.down") }
                        if let share = exportURL ?? (quarterTurns == 0 ? item.url : nil) { ShareLink(item: share) { Label("分享 / 存储到文件", systemImage:"square.and.arrow.up") } }
                    } label: { Image(systemName:"ellipsis.circle") }
                }
            }
            .task { updateExport() }
            .alert("提示",isPresented:Binding(get:{message != nil},set:{if !$0{message=nil}})){Button("好",role:.cancel){}}message:{Text(message ?? "")}
        }
    }

    @MainActor private func updateExport() {
        guard quarterTurns != 0, let image else { exportURL = nil; return }
        do { exportURL = try Self.rotatedPNG(image, quarterTurns: quarterTurns) }
        catch { message = error.localizedDescription }
    }
    @MainActor private func savePhoto() async {
        let url = exportURL ?? item.url
        do { try await LocalImageExporter.shared.saveToPhotos(path: url.path); message = "已保存到照片" }
        catch { message = error.localizedDescription }
    }

    @MainActor private func addToImageLibrary() async {
        let url = exportURL ?? item.url
        do {
            let asset = try await ImageAssetLibrary.shared.importImage(from: url, name: "\(item.book.title) · EPUB 图片")
            try await ImageAssetLibrary.shared.update(id: asset.id, purpose: "EPUB 图片")
            message = "已加入图片库"
        } catch { message = error.localizedDescription }
    }
    @MainActor private func setAsCover() async {
        let url = exportURL ?? item.url
        do { _ = try await LocalImageExporter.shared.setBookCover(book: item.book, imagePath: url.path); message = "已设为本书封面" }
        catch { message = error.localizedDescription }
    }
    private static func rotatedPNG(_ image: UIImage, quarterTurns: Int) throws -> URL {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return URL(fileURLWithPath: "") }
        let swapped = turns % 2 == 1
        let size = swapped ? CGSize(width: image.size.height, height: image.size.width) : image.size
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: size.width/2, y: size.height/2)
            c.rotate(by: CGFloat(turns) * .pi/2)
            let rect = CGRect(x: -image.size.width/2, y: -image.size.height/2, width: image.size.width, height: image.size.height)
            image.draw(in: rect)
        }
        guard let data = rendered.pngData() else { throw LocalImageExporter.ExportError.failed }
        try FileManager.default.createDirectory(at: AppPaths.exports, withIntermediateDirectories: true)
        let url = AppPaths.exports.appendingPathComponent("EPUB-image-\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic); return url
    }
}
