import SwiftUI

struct CompanionAutonomySettingsView: View {
    @ObservedObject private var store = CompanionAutonomySettingsStore.shared
    var body: some View {
        Form {
            Section("对话呈现") {
                Toggle("多气泡回复", isOn: $store.multiBubbleReplies)
                Toggle("显示伴读 Token 用量", isOn: $store.showTokenUsage)
                Toggle("AI 建议回复", isOn: $store.suggestionRepliesEnabled)
                Toggle("显示 AI 批注", isOn: $store.showAIAnnotations)
                Toggle("伴读防剧透", isOn: $store.spoilerProtectionEnabled)
                Text("防剧透默认开启：书内和书库伴读的正文工具只读取已读水位。关闭后模型工具可读取整本书，可能直接涉及后续剧情。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("开启 AI 建议回复后，每次完整 AI 回合结束会额外调用一次建议模型，生成最多 3 条快捷回复；未配置建议模型时按 CHEAP → CHAT 回落。关闭后不会自动产生这笔调用。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("开启多气泡后普通短句按行拆成气泡；列表、代码和 [整段] 块保持完整。语音消息无论此开关如何都单独显示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("自主付费能力") {
                Toggle("允许角色自主语音回复", isOn: $store.voiceRepliesEnabled)
                Toggle("允许角色自主生成插图", isOn: $store.imageRepliesEnabled)
                Text("这两项默认关闭。关闭时应用不会把相应标记规则或 generate_image 工具告诉模型；不是等模型调用后再拦截。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("费用与边界") {
                Text("自主语音只有角色已经绑定音色时才生效，每条回复最多合成 2 段；自主插图只能引用已读范围内可逐字核验的原文场景。生图会再次执行 ReadingScope 校验和参考图能力限制。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("伴读自主行为")
    }
}
