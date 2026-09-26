import SwiftUI

struct BookCoverManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let book: Book
    @State private var results: [OnlineBookCover] = []
    @State private var searching = false
    @State private var generating = false
    @State private var customPrompt = ""
    @State private var errorText: String?
    @State private var infoText: String?

    var body: some View {
        NavigationStack {
            List {
                Section("网络找封面") {
                    Button { Task { await search() } } label: {
                        Label(searching ? "正在搜索…" : "搜索正式出版封面", systemImage: "magnifyingglass")
                    }.disabled(searching || generating)
                    if results.isEmpty && !searching { Text("优先使用已配置的图片搜索服务；未配置时自动回落 Open Library / Google Books。") .font(.footnote).foregroundStyle(.secondary) }
                    ForEach(results) { cover in
                        HStack(alignment: .top, spacing: 12) {
                            AsyncImage(url: URL(string: cover.imageURL)) { phase in
                                switch phase {
                                case .success(let image): image.resizable().scaledToFill()
                                case .failure: Color.secondary.opacity(0.12).overlay { Image(systemName: "photo") }
                                default: ProgressView()
                                }
                            }.frame(width: 72, height: 104).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(cover.title).font(.headline).lineLimit(2)
                                if !cover.author.isEmpty { Text(cover.author).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                Text(cover.source).font(.caption2).foregroundStyle(.tertiary)
                                Button("使用这张封面") { Task { await use(cover) } }.buttonStyle(.bordered)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Section("AI 生成封面") {
                    TextField("可选：补充风格或构图要求", text: $customPrompt, axis: .vertical).lineLimit(2...6)
                    Button { Task { await generate() } } label: {
                        Label(generating ? "正在生成…" : "生成并设为封面", systemImage: "wand.and.stars")
                    }.disabled(searching || generating)
                    Text("复用当前生图 API、画风和参考图能力。不会把生成内容写进正文。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("本地图片") {
                    NavigationLink("从图片库选择") { ImageLibraryView() }
                }
                if let infoText { Section { Text(infoText).foregroundStyle(.secondary) } }
            }
            .navigationTitle("书籍封面")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .alert("封面操作失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorText ?? "") }
        }
    }

    @MainActor private func search() async {
        searching = true; defer { searching = false }
        do { let value = try await BookCoverService.shared.search(book: book); results = value.covers; infoText = results.isEmpty ? "没有找到可用封面" : "找到 \(results.count) 张候选" }
        catch { errorText = error.localizedDescription }
    }

    @MainActor private func use(_ cover: OnlineBookCover) async {
        do {
            let temp = try await BookCoverService.shared.download(cover)
            defer { try? FileManager.default.removeItem(at: temp) }
            let asset = try await ImageAssetLibrary.shared.importImage(from: temp, name: "\(book.title) 封面")
            try await ImageAssetLibrary.shared.update(id: asset.id, purpose: "封面")
            _ = try await LocalImageExporter.shared.setBookCover(book: book, imagePath: asset.filePath)
            try await library.refresh(); infoText = "已更新书籍封面"
        } catch { errorText = error.localizedDescription }
    }

    @MainActor private func generate() async {
        generating = true; defer { generating = false }
        do {
            let draft = try await BookCoverService.shared.generate(book: book, customPrompt: customPrompt)
            defer { try? FileManager.default.removeItem(at: draft) }
            _ = try await LocalImageExporter.shared.setBookCover(book: book, imagePath: draft.path)
            try await library.refresh(); infoText = "AI 封面已生成并应用"
        } catch { errorText = error.localizedDescription }
    }
}
