import SwiftUI

struct UserMaskSettingsView: View {
    @ObservedObject private var store = UserMaskStore.shared
    @State private var editing: UserMask?
    @State private var creating = false
    var body: some View {
        List {
            Section {
                Toggle("启用用户面具", isOn: Binding(get: { store.settings.enabled }, set: { store.setEnabled($0) }))
                if store.settings.masks.isEmpty { Text("创建一个用户面具后，可以告诉角色“我是谁”；它不会替代 AI 角色卡。") .font(.footnote).foregroundStyle(.secondary) }
            }
            Section("面具") {
                ForEach(store.settings.masks) { mask in
                    HStack {
                        Button { store.select(mask.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mask.name)
                                Text(mask.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.buttonStyle(.plain)
                        Spacer()
                        if store.settings.activeMaskId == mask.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        Button { editing = mask } label: { Image(systemName: "pencil") }.buttonStyle(.plain)
                    }
                }.onDelete { offsets in offsets.map { store.settings.masks[$0].id }.forEach(store.delete) }
            }
        }
        .navigationTitle("用户面具")
        .toolbar { Button { creating = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $creating) { NavigationStack { UserMaskEditor(mask: nil) { creating = false } } }
        .sheet(item: $editing) { mask in NavigationStack { UserMaskEditor(mask: mask) { editing = nil } } }
    }
}

private struct UserMaskEditor: View {
    let mask: UserMask?
    let dismissEditor: () -> Void
    @State private var name: String
    @State private var description: String
    @State private var error: String?
    init(mask: UserMask?, dismissEditor: @escaping () -> Void) {
        self.mask = mask; self.dismissEditor = dismissEditor
        _name = State(initialValue: mask?.name ?? "")
        _description = State(initialValue: mask?.description ?? "")
    }
    var body: some View {
        Form {
            TextField("名称", text: $name)
            TextEditor(text: $description).frame(minHeight: 180)
            Text("描述你希望角色知道的用户身份、称呼、背景或偏好。不要把密码、API Key 等秘密放在这里。") .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle(mask == nil ? "新建面具" : "编辑面具")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", action: dismissEditor) }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { do { _ = try UserMaskStore.shared.save(.init(id: mask?.id ?? 0, name: name, description: description)); dismissEditor() } catch { self.error = error.localizedDescription } } }
        }
        .alert("保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
    }
}
