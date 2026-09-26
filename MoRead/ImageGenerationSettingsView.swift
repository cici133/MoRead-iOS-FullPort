import SwiftUI

struct ImageGenerationSettingsView: View {
    @ObservedObject private var store = ImageAPISettingsStore.shared
    @State private var testing = false
    @State private var resultText = ""

    private let samplers = ["k_euler_ancestral", "k_euler", "k_dpmpp_2m", "k_dpmpp_2s_ancestral", "k_dpmpp_sde", "ddim_v3"]

    var body: some View {
        Form {
            Section("独立生图服务") {
                Picker("协议 / 后端", selection: Binding(
                    get: { store.settings.provider },
                    set: { store.switchProvider($0) }
                )) {
                    ForEach(ImageAPIProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Base URL", text: $store.settings.baseURL)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("模型", text: $store.settings.model)
                    .textInputAutocapitalization(.never)
                SecureField("API Key", text: $store.apiKey)
                Picker("默认尺寸", selection: $store.settings.size) {
                    ForEach(store.settings.provider.sizeOptions, id: \.self) { Text($0).tag($0) }
                }
                Button(testing ? "正在检查…" : "检查配置") { Task { await testConfiguration() } }.disabled(testing)
                if !resultText.isEmpty { Text(resultText).font(.caption).foregroundStyle(.secondary) }
            }

            if store.settings.provider == .novelAI {
                Section("NovelAI") {
                    TextField("固定正面标签", text: $store.settings.positivePrompt, axis: .vertical).lineLimit(2...6)
                    TextField("固定负面标签", text: $store.settings.negativePrompt, axis: .vertical).lineLimit(2...6)
                    Picker("采样器", selection: $store.settings.sampler) {
                        ForEach(samplers, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("Steps：\(store.settings.steps)", value: $store.settings.steps, in: 1...50)
                    LabeledContent("Guidance：\(store.settings.scale.formatted(.number.precision(.fractionLength(1))))") {
                        Slider(value: $store.settings.scale, in: 0...10, step: 0.1)
                    }
                    Text("NovelAI v4/v5 支持 Vibe；v4.5 支持单人物角色参考。角色参考与 Vibe 不能在同一张图同时使用，工作室会按模型能力自动裁剪引用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if store.settings.provider == .openAIChat {
                Section {
                    Text("用于通过 /chat/completions 返回图片的中转或多模态模型。参考图会作为 data URL 多模态输入发送。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("无参考图时使用 /images/generations；使用参考图时切换到 /images/edits。具体参考图数量由当前模型能力限制。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("优先级") {
                Text("这里的 Base URL 和模型填写完整后，插图工作室优先使用独立生图配置；留空则回到 AI 服务 → IMAGE 角色分配。API Key 只保存在 Keychain。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("生图服务")
        .onAppear {
            if store.settings.baseURL.isEmpty { store.settings.baseURL = store.settings.provider.defaultBaseURL }
            if store.settings.model.isEmpty { store.settings.model = store.settings.provider.defaultModel }
            if store.settings.size.isEmpty { store.settings.size = store.settings.provider.sizeOptions[0] }
        }
    }

    @MainActor private func testConfiguration() async {
        testing = true; defer { testing = false }
        if !store.settings.configured { resultText = "请填写 Base URL 和模型"; return }
        if store.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { resultText = "请填写 API Key"; return }
        let label = await ImageGenerationService.shared.backendLabel()
        let caps = await ImageGenerationService.shared.capabilities()
        resultText = "已读取：\(label) · 参考图上限 \(caps.maxReferences) · 人物参考上限 \(caps.maxCharacterReferences)"
    }
}
