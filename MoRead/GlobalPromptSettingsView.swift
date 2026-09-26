import SwiftUI

struct GlobalPromptSettingsView: View {
    @ObservedObject private var store = GlobalPromptPresetStore.shared
    @State private var editing: GlobalPromptPreset?
    @State private var creating = false
    var body: some View {
        List {
            Section { Text("启用的预设只注入本次请求副本，不会修改数据库中保存的用户原消息。") .font(.footnote).foregroundStyle(.secondary) }
            ForEach(store.presets) { preset in
                HStack(alignment: .top) {
                    Toggle("", isOn: Binding(get: { preset.enabled }, set: { store.setEnabled(id: preset.id, enabled: $0) })).labelsHidden()
                    Button { editing = preset } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(preset.name).font(.headline); if preset.builtIn { Text("内置").font(.caption2).padding(.horizontal,5).background(.thinMaterial,in:Capsule()) } }
                            Text(preset.position.label).font(.caption).foregroundStyle(.secondary)
                            Text(preset.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }.buttonStyle(.plain)
                }
            }.onDelete { offsets in offsets.map { store.presets[$0] }.filter { !$0.builtIn }.forEach { store.delete($0.id) } }
        }
        .navigationTitle("全局预设")
        .toolbar { Button { creating = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $creating) { NavigationStack { GlobalPromptEditor(preset: nil) { creating = false } } }
        .sheet(item: $editing) { item in NavigationStack { GlobalPromptEditor(preset: item) { editing = nil } } }
    }
}

private struct GlobalPromptEditor: View {
    let preset: GlobalPromptPreset?
    let done: () -> Void
    @State private var name: String
    @State private var prompt: String
    @State private var position: GlobalPromptInjectionPosition
    @State private var enabled: Bool
    @State private var error: String?
    init(preset: GlobalPromptPreset?, done: @escaping () -> Void) {
        self.preset = preset; self.done = done
        _name = State(initialValue: preset?.name ?? "")
        _prompt = State(initialValue: preset?.prompt ?? "")
        _position = State(initialValue: preset?.position ?? .afterSystem)
        _enabled = State(initialValue: preset?.enabled ?? false)
    }
    var body: some View {
        Form {
            TextField("名称", text: $name)
            Picker("注入位置", selection: $position) { ForEach(GlobalPromptInjectionPosition.allCases) { Text($0.label).tag($0) } }
            Toggle("启用", isOn: $enabled)
            TextEditor(text: $prompt).frame(minHeight: 220)
        }
        .navigationTitle(preset == nil ? "新建全局预设" : "编辑全局预设")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", action: done) }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { do { try GlobalPromptPresetStore.shared.upsert(.init(id: preset?.id ?? "", name: name, prompt: prompt, enabled: enabled, position: position, builtIn: preset?.builtIn ?? false)); done() } catch { self.error = error.localizedDescription } } }
        }
        .alert("保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
    }
}
