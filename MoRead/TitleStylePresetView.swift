import SwiftUI
import UIKit

struct TitleStylePresetManagerView: View {
    @ObservedObject private var store = ReaderEnhancementSettingsStore.shared
    @State private var editing: NamedReaderTitleStyle?
    @State private var createFromCurrent = false

    private var presets: [NamedReaderTitleStyle] { store.settings.resolvedTitlePresets }

    var body: some View {
        List {
            Section("当前样式") {
                Button("编辑当前章首样式") { editing = .init(id: store.settings.activeTitleStyleId ?? UUID().uuidString, name: currentName, style: store.settings.titleStyle) }
                Button("把当前样式另存为…") { createFromCurrent = true }
            }
            Section("我的章首样式") {
                if presets.isEmpty { Text("还没有保存的章首样式").foregroundStyle(.secondary) }
                ForEach(presets) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.name)
                            Text(summary(preset.style)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.settings.activeTitleStyleId == preset.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        Menu {
                            Button("应用") { apply(preset) }
                            Button("编辑") { editing = preset }
                            Button("复制") { duplicate(preset) }
                            Button(role: .destructive) { delete(preset) } label: { Text("删除") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { apply(preset) }
                }
            }
            Section {
                Text("删除保存样式不会改变当前已经应用的外观快照；因此阅读中的章首不会突然变回默认。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("章首样式")
        .sheet(item: $editing) { preset in
            NamedTitleStyleEditor(preset: preset) { save($0, applyAfterSave: true) }
        }
        .sheet(isPresented: $createFromCurrent) {
            NamedTitleStyleEditor(preset: .init(name: "新章首样式", style: store.settings.titleStyle)) { save($0, applyAfterSave: true) }
        }
    }

    private var currentName: String { presets.first(where: { $0.id == store.settings.activeTitleStyleId })?.name ?? "当前样式" }
    private func apply(_ preset: NamedReaderTitleStyle) { store.settings.titleStyle = preset.style; store.settings.activeTitleStyleId = preset.id }
    private func save(_ preset: NamedReaderTitleStyle, applyAfterSave: Bool) {
        var list = presets
        if let index = list.firstIndex(where: { $0.id == preset.id }) { list[index] = preset } else { list.append(preset) }
        store.settings.titleStylePresets = list
        if applyAfterSave { apply(preset) }
    }
    private func duplicate(_ preset: NamedReaderTitleStyle) { save(.init(id: UUID().uuidString, name: preset.name + " 副本", style: preset.style), applyAfterSave: false) }
    private func delete(_ preset: NamedReaderTitleStyle) {
        store.settings.titleStylePresets = presets.filter { $0.id != preset.id }
        if store.settings.activeTitleStyleId == preset.id { store.settings.activeTitleStyleId = nil }
    }
    private func summary(_ s: ReaderTitleStyle) -> String { "\(Int(s.fontSizeEm * 100))% · \(s.alignment) · \(s.backgroundImagePath == nil ? "纯色" : "图片背景")" }
}

private struct NamedTitleStyleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var preset: NamedReaderTitleStyle
    let save: (NamedReaderTitleStyle) -> Void
    @State private var assets: [ImageAssetRecord] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("样式名称", text: $preset.name) }
                Section("排版") {
                    Toggle("显示阅读器章首", isOn: $preset.style.enabled)
                    TextField("字体族", text: $preset.style.fontFamily)
                    Stepper("字号 \(preset.style.fontSizeEm, specifier: "%.2f") em", value: $preset.style.fontSizeEm, in: 0.5...3, step: 0.05)
                    Picker("对齐", selection: $preset.style.alignment) { Text("左").tag("left"); Text("中").tag("center"); Text("右").tag("right") }
                    TextField("文字颜色 Hex（空=正文）", text: $preset.style.colorHex)
                    TextField("背景颜色 Hex（可空）", text: $preset.style.backgroundHex)
                    Stepper("上间距 \(preset.style.marginTopEm, specifier: "%.1f") em", value: $preset.style.marginTopEm, in: 0...6, step: 0.1)
                    Stepper("下间距 \(preset.style.marginBottomEm, specifier: "%.1f") em", value: $preset.style.marginBottomEm, in: 0...6, step: 0.1)
                    Stepper("内边距 \(preset.style.paddingEm, specifier: "%.1f") em", value: $preset.style.paddingEm, in: 0...6, step: 0.1)
                    TextField("边框颜色 Hex（可空）", text: $preset.style.borderColorHex)
                    Stepper("边框 \(preset.style.borderWidthEm, specifier: "%.2f") em", value: $preset.style.borderWidthEm, in: 0...0.5, step: 0.02)
                    Stepper("圆角 \(preset.style.borderRadiusEm, specifier: "%.1f") em", value: $preset.style.borderRadiusEm, in: 0...6, step: 0.1)
                }
                Section("章首背景图") {
                    Picker("图片", selection: Binding(get: { preset.style.backgroundImagePath ?? "" }, set: { preset.style.backgroundImagePath = $0.isEmpty ? nil : $0 })) {
                        Text("无").tag("")
                        ForEach(assets) { Text($0.name).tag($0.filePath) }
                    }
                    if let path = preset.style.backgroundImagePath, let ui = UIImage(contentsOfFile: path) {
                        Image(uiImage: ui).resizable().scaledToFill().frame(height: 120).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .navigationTitle("章首样式")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { preset.name = String(preset.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)); if preset.name.isEmpty { preset.name = "章首样式" }; save(preset); dismiss() } }
            }
            .task { assets = (try? await ImageAssetLibrary.shared.list()) ?? [] }
        }
    }
}
