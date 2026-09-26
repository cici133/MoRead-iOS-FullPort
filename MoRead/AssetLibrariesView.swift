import CoreText
import SwiftUI
import UIKit

struct FontLibraryView: View {
    @ObservedObject private var app = AppPlatformSettingsStore.shared
    @ObservedObject private var reader = ReaderSettingsStore.shared
    @State private var fonts: [ReaderFontAsset] = []
    @State private var importing = false
    @State private var errorText: String?

    var body: some View {
        List {
            Section("当前使用") {
                Picker("App 界面字体", selection: $app.appFontPostScriptName) {
                    Text("系统默认").tag("")
                    ForEach(fonts) { Text($0.displayName).tag($0.postScriptName) }
                }
                Picker("阅读正文字体", selection: $reader.preferences.fontFamily) {
                    Text("系统默认").tag("-apple-system")
                    ForEach(fonts) { Text($0.displayName).tag("'\($0.postScriptName)'") }
                }
                Picker("阅读章首字体", selection: $reader.preferences.titleFontFamily) {
                    Text("系统默认").tag("-apple-system")
                    ForEach(fonts) { Text($0.displayName).tag("'\($0.postScriptName)'") }
                }
            }
            Section("字体库") {
                Button { importing = true } label: { Label("导入 TTF / OTF", systemImage: "plus") }
                if fonts.isEmpty { Text("还没有自定义字体").foregroundStyle(.secondary) }
                ForEach(fonts) { font in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(font.displayName).font(.custom(font.postScriptName, size: 18))
                        Text(font.postScriptName).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("设为 App 字体") { app.appFontPostScriptName = font.postScriptName }
                            Button("设为阅读字体") { reader.preferences.fontFamily = "'\(font.postScriptName)'" }
                            Spacer()
                            Button(role: .destructive) { delete(font) } label: { Image(systemName: "trash") }
                        }.font(.caption)
                    }.padding(.vertical, 4)
                }
            }
            Section {
                Text("同一字体资产可同时用于 App 界面、正文和章首；删除正在使用的字体时会自动回退系统字体。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("字体库")
        .task { reload() }
        .sheet(isPresented: $importing) {
            ExtensionFilePicker(extensions: ["ttf", "otf"]) { urls in
                importing = false
                guard let url = urls.first else { return }
                importFont(url)
            }
        }
        .alert("字体库", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { }
        } message: { Text(errorText ?? "") }
    }

    private func reload() { fonts = ReaderFontLibrary.assets() }
    private func importFont(_ url: URL) {
        do {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let dir = ReaderFontLibrary.directory(); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent("\(UUID().uuidString).\(url.pathExtension.lowercased())")
            try FileManager.default.copyItem(at: url, to: target)
            guard ReaderFontLibrary.register(target) != nil else { try? FileManager.default.removeItem(at: target); throw ReaderEnhancementError.message("无法读取字体") }
            reload()
        } catch { errorText = error.localizedDescription }
    }
    private func delete(_ font: ReaderFontAsset) {
        let templateNames = ReviewShareTemplateStore.shared.templates
            .filter { $0.fontChoice.trimmingCharacters(in: .whitespacesAndNewlines) == font.postScriptName }
            .map(\.name)
        guard templateNames.isEmpty else {
            errorText = "字体仍被回顾分享模板使用：\(templateNames.joined(separator: "、"))。请先修改这些模板的字体。"
            return
        }
        if app.appFontPostScriptName == font.postScriptName { app.appFontPostScriptName = "" }
        if reader.preferences.fontFamily.contains(font.postScriptName) { reader.preferences.fontFamily = "-apple-system" }
        if reader.preferences.titleFontFamily.contains(font.postScriptName) { reader.preferences.titleFontFamily = "-apple-system" }
        var error: Unmanaged<CFError>?
        CTFontManagerUnregisterFontsForURL(URL(fileURLWithPath: font.path) as CFURL, .process, &error)
        do { try FileManager.default.removeItem(atPath: font.path); reload() } catch { errorText = error.localizedDescription }
    }
}

struct ImageLibraryView: View {
    @ObservedObject private var reader = ReaderSettingsStore.shared
    @State private var assets: [ImageAssetRecord] = []
    @State private var books: [Book] = []
    @State private var importing = false
    @State private var editing: ImageAssetRecord?
    @State private var coverAsset: ImageAssetRecord?
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("图片库").font(.title2.bold())
                        Text("阅读背景、封面、插图参考与分享模板共用同一份本地资产。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(); Button { importing = true } label: { Label("导入", systemImage: "plus") }.buttonStyle(.borderedProminent)
                }
                if assets.isEmpty { ContentUnavailableView("还没有图片", systemImage: "photo.on.rectangle") }
                else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(assets) { asset in
                            VStack(alignment: .leading, spacing: 7) {
                                if let ui = UIImage(contentsOfFile: asset.filePath) {
                                    Image(uiImage: ui).resizable().scaledToFill().frame(height: 145).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                Text(asset.name).font(.headline).lineLimit(1)
                                Text(asset.effectivePurpose).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("阅读背景") { reader.preferences.theme.backgroundImagePath = asset.filePath; Task { try? await ImageAssetLibrary.shared.update(id: asset.id, purpose: "阅读背景") } }
                                    Menu {
                                        Button("设为书籍封面…") { coverAsset = asset }
                                        Button("编辑名称 / 用途") { editing = asset }
                                        ShareLink(item: URL(fileURLWithPath: asset.filePath)) { Label("分享", systemImage: "square.and.arrow.up") }
                                        Button(role: .destructive) { delete(asset) } label: { Label("删除", systemImage: "trash") }
                                    } label: { Image(systemName: "ellipsis.circle") }
                                }.font(.caption)
                            }
                        }
                    }
                }
            }.padding()
        }
        .navigationTitle("图片库")
        .task { await reload() }
        .sheet(isPresented: $importing) { ExtensionFilePicker(extensions: ["png", "jpg", "jpeg", "webp"]) { urls in importing = false; Task { await importImages(urls) } } }
        .sheet(item: $editing) { asset in ImageAssetEditor(asset: asset) { Task { await reload() } } }
        .sheet(item: $coverAsset) { asset in CoverBookPicker(asset: asset, books: books) { Task { await reload() } } }
        .alert("图片库", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorText ?? "") }
    }

    @MainActor private func reload() async {
        assets = (try? await ImageAssetLibrary.shared.list()) ?? []
        books = (try? await LibraryRepository.shared.listBooks()) ?? []
    }
    @MainActor private func importImages(_ urls: [URL]) async {
        do { for url in urls { _ = try await ImageAssetLibrary.shared.importImage(from: url) }; await reload() }
        catch { errorText = error.localizedDescription }
    }
    private func delete(_ asset: ImageAssetRecord) {
        if reader.preferences.theme.backgroundImagePath == asset.filePath { reader.preferences.theme.backgroundImagePath = nil }
        Task { do { try await ImageAssetLibrary.shared.delete(id: asset.id); await reload() } catch { await MainActor.run { errorText = error.localizedDescription } } }
    }
}

private struct ImageAssetEditor: View {
    @Environment(\.dismiss) private var dismiss
    let asset: ImageAssetRecord
    let changed: () -> Void
    @State private var name: String
    @State private var purpose: String
    init(asset: ImageAssetRecord, changed: @escaping () -> Void) { self.asset = asset; self.changed = changed; _name = State(initialValue: asset.name); _purpose = State(initialValue: asset.effectivePurpose) }
    var body: some View {
        NavigationStack { Form {
            TextField("名称", text: $name)
            Picker("用途", selection: $purpose) { ForEach(["未分类","阅读背景","封面","人物参考","画风参考","分享模板"], id: \.self) { Text($0) } }
        }.navigationTitle("图片资产").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { try? await ImageAssetLibrary.shared.update(id: asset.id, name: name, purpose: purpose); changed(); dismiss() } } }
        }}
    }
}

private struct CoverBookPicker: View {
    @Environment(\.dismiss) private var dismiss
    let asset: ImageAssetRecord
    let books: [Book]
    let changed: () -> Void
    @State private var errorText: String?
    var body: some View {
        NavigationStack { List(books) { book in
            Button { set(book) } label: { HStack { Text(book.title); Spacer(); Image(systemName: "book.closed") } }
        }.navigationTitle("设为书籍封面").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .alert("设置封面失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorText ?? "") }}
    }
    private func set(_ book: Book) { Task { do { _ = try await LocalImageExporter.shared.setBookCover(book: book, imagePath: asset.filePath); try? await ImageAssetLibrary.shared.update(id: asset.id, purpose: "封面"); changed(); dismiss() } catch { errorText = error.localizedDescription } } }
}
