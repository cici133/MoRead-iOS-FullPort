import SwiftUI

struct CompanionMemorySettingsView: View {
    @ObservedObject private var store = CompanionMemorySettingsStore.shared
    var body: some View {
        Form {
            Section("伴读记忆") {
                Toggle("长期记忆", isOn: $store.settings.longTermEnabled)
                Toggle("跨书记忆", isOn: $store.settings.crossBookEnabled).disabled(!store.settings.longTermEnabled)
                Toggle("跨书对话检索", isOn: $store.settings.crossBookChatSearch).disabled(!store.settings.longTermEnabled)
            }
            Section {
                Text("长期记忆关闭时不会固化、召回，也不会向模型注册 recall_memory。跨书记忆控制自动召回和用户画像在不同书之间的共享；跨书对话检索控制模型是否可主动检索其他书的相关记忆。用户面具不会写进真实用户画像。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("伴读记忆")
    }
}
