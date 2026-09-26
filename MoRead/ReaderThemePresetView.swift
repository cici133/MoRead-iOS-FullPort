import SwiftUI

struct ReaderThemePresetManagerView: View {
    @ObservedObject private var reader = ReaderSettingsStore.shared
    @ObservedObject private var enhancements = ReaderEnhancementSettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var newName = ""
    @State private var editing: NamedReaderThemePreset?

    private var presets: [NamedReaderThemePreset] { reader.preferences.resolvedThemePresets }

    var body: some View {
        List {
            Section("日夜主题") {
                Toggle("跟随系统明暗切换阅读主题", isOn: Binding(
                    get: { reader.preferences.automaticDayNightThemeEnabled },
                    set: { reader.preferences.dayNightThemeAuto = $0 }
                ))
                Picker("日间主题", selection: optionalId(\.dayThemePresetId)) {
                    Text("当前手动设置").tag(String?.none)
                    ForEach(presets) { Text($0.name).tag(Optional($0.id)) }
                }
                if reader.preferences.automaticDayNightThemeEnabled {
                    Picker("夜间主题", selection: optionalId(\.nightThemePresetId)) {
                        Text("当前手动设置").tag(String?.none)
                        ForEach(presets) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
            Section("保存当前阅读外观") {
                TextField("主题名称", text: $newName)
                Button("保存完整主题快照") { saveCurrent() }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("我的主题") {
                if presets.isEmpty { Text("还没有自定义阅读主题").foregroundStyle(.secondary) }
                ForEach(presets) { preset in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(moreadHex: preset.theme.backgroundHex) ?? .secondary.opacity(0.15))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(moreadHex: preset.theme.accentHex) ?? .secondary, lineWidth: 2))
                            .frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.name)
                            Text("\(Int(preset.fontSize)) pt · 行距 " + String(format: "%.2f", preset.lineHeight) + " · " + (preset.titleStyle.enabled ? "含章首样式" : "无章首样式"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("应用到当前手动设置") { apply(preset) }
                            Button("设为日间主题") { reader.preferences.dayThemePresetId = preset.id }
                            Button("设为夜间主题") { reader.preferences.nightThemePresetId = preset.id }
                            Button("编辑名称") { editing = preset }
                            Button("复制") { duplicate(preset) }
                            Button(role: .destructive) { delete(preset) } label: { Text("删除") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { apply(preset) }
                }
            }
            Section {
                Text("主题保存完整排版和章首快照。删除预设不会改掉当前正在使用的手动外观；悬空的日/夜或单书引用会自动回退当前手动设置。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("阅读主题")
        .sheet(item: $editing) { preset in RenameReaderThemeView(preset: preset) { update($0) } }
    }

    private func optionalId(_ keyPath: WritableKeyPath<ReaderPreferences, String?>) -> Binding<String?> {
        Binding(get: { reader.preferences[keyPath: keyPath] }, set: { reader.preferences[keyPath: keyPath] = $0 })
    }

    private func saveCurrent() {
        let name = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty else { return }
        var list = presets
        list.append(.init(name: name, preferences: reader.preferences, titleStyle: enhancements.settings.titleStyle, isDark: colorScheme == .dark))
        reader.preferences.themePresets = list
        newName = ""
    }

    private func apply(_ preset: NamedReaderThemePreset) {
        let preserved = reader.preferences
        var applied = preserved.applying(preset)
        // Applying a snapshot must not overwrite the preset library, auto-switch policy or per-book bindings.
        applied.themePresets = preserved.themePresets
        applied.dayThemePresetId = preserved.dayThemePresetId
        applied.nightThemePresetId = preserved.nightThemePresetId
        applied.dayNightThemeAuto = preserved.dayNightThemeAuto
        applied.bookThemeOverrides = preserved.bookThemeOverrides
        reader.preferences = applied
        enhancements.settings.titleStyle = preset.titleStyle
    }

    private func update(_ preset: NamedReaderThemePreset) {
        var list = presets
        if let i = list.firstIndex(where: { $0.id == preset.id }) { list[i] = preset }
        reader.preferences.themePresets = list
    }
    private func duplicate(_ preset: NamedReaderThemePreset) {
        var copy = preset; copy.id = UUID().uuidString; copy.name += " 副本"
        var list = presets; list.append(copy); reader.preferences.themePresets = list
    }
    private func delete(_ preset: NamedReaderThemePreset) {
        reader.preferences.themePresets = presets.filter { $0.id != preset.id }
        if reader.preferences.dayThemePresetId == preset.id { reader.preferences.dayThemePresetId = nil }
        if reader.preferences.nightThemePresetId == preset.id { reader.preferences.nightThemePresetId = nil }
        var overrides = reader.preferences.resolvedBookThemeOverrides
        for (bookId, var value) in overrides {
            if value.dayPresetId == preset.id { value.dayPresetId = nil }
            if value.nightPresetId == preset.id { value.nightPresetId = nil }
            overrides[bookId] = value
        }
        reader.preferences.bookThemeOverrides = overrides
    }
}

private struct RenameReaderThemeView: View {
    @Environment(\.dismiss) private var dismiss
    @State var preset: NamedReaderThemePreset
    let save: (NamedReaderThemePreset) -> Void
    var body: some View {
        NavigationStack {
            Form { TextField("主题名称", text: $preset.name) }
                .navigationTitle("重命名主题")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { preset.name = String(preset.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)); if !preset.name.isEmpty { save(preset); dismiss() } } }
                }
        }
    }
}
