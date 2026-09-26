import SwiftUI
import UIKit

struct CharacterTurnaroundCandidatesView: View {
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let chapterIndex: Int
    let look: LookSpec
    var onAccepted: (LookSpec) async -> Void

    @State private var candidates: [GeneratedIllustration] = []
    @State private var selected = 0
    @State private var busy = false
    @State private var errorText: String?
    @State private var backend = ""
    @State private var capabilities = ImageCapabilities()
    @State private var accepted = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("人物形象") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(look.name).font(.headline)
                            Text((look.natural.isEmpty ? look.tags : look.natural).isEmpty ? "尚未填写外貌描述" : (look.natural.isEmpty ? look.tags : look.natural))
                                .font(.callout).foregroundStyle(.secondary)
                            LabeledContent("后端", value: backend.isEmpty ? "未配置" : backend)
                            LabeledContent("人物参考能力", value: capabilities.maxCharacterReferences > 0 ? "支持" : "仅文字形象")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if candidates.isEmpty {
                        GroupBox("三视图候选") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("会生成 4 张人物参考候选。每张都要求正面 / 3/4 / 侧面 / 背面、全身和面部特写，纯背景、无文字。")
                                    .font(.callout)
                                Text("这是付费生图请求。现有角色参考图和本书画风会在当前后端允许时参与生成。")
                                    .font(.caption).foregroundStyle(.orange)
                                Button {
                                    generate()
                                } label: {
                                    if busy { ProgressView() } else { Label("生成 4 个候选", systemImage: "person.crop.rectangle.stack") }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(busy || backend.isEmpty || backend == "未配置")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("选择一个候选").font(.headline)
                            TabView(selection: $selected) {
                                ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                                    ZStack(alignment: .topTrailing) {
                                        if let image = UIImage(contentsOfFile: candidate.imagePath) {
                                            Image(uiImage: image)
                                                .resizable().scaledToFit()
                                                .padding(8)
                                        } else {
                                            ContentUnavailableView("候选图片已失效", systemImage: "photo.badge.exclamationmark")
                                        }
                                        Text("候选 \(index + 1)")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(.ultraThinMaterial, in: Capsule())
                                            .padding(12)
                                    }
                                    .tag(index)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .automatic))
                            .frame(minHeight: 420)

                            HStack {
                                Button("重新生成") { cleanupCandidates(); generate() }
                                    .buttonStyle(.bordered)
                                    .disabled(busy)
                                Spacer()
                                Button("采用为人物参考") { acceptSelected() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(busy || !candidates.indices.contains(selected))
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("三视图候选 · \(look.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .task {
                backend = await ImageGenerationService.shared.backendLabel()
                capabilities = await ImageGenerationService.shared.capabilities()
            }
            .onDisappear { if !accepted { cleanupCandidates() } }
            .alert("人物参考图", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) { }
            } message: { Text(errorText ?? "") }
        }
    }

    @MainActor
    private func generate() {
        guard !busy else { return }
        busy = true
        Task {
            do {
                let values = try await ImageConsistencyRepository.shared.turnaroundCandidates(
                    bookId: book.id,
                    chapterIndex: max(chapterIndex, look.sinceChapter),
                    look: look,
                    count: 4
                )
                await MainActor.run { candidates = values; selected = 0; busy = false }
            } catch is CancellationError {
                await MainActor.run { busy = false }
            } catch {
                await MainActor.run { errorText = error.localizedDescription; busy = false }
            }
        }
    }

    @MainActor
    private func acceptSelected() {
        guard candidates.indices.contains(selected), !busy else { return }
        busy = true
        let candidate = candidates[selected]
        Task {
            do {
                let asset = try await ImageAssetLibrary.shared.importImage(from: URL(fileURLWithPath: candidate.imagePath), name: "\(look.name) · 三视图")
                try await ImageAssetLibrary.shared.update(id: asset.id, purpose: "人物参考")
                var updated = look
                updated.referenceIds = [asset.id] + look.referenceIds.filter { $0 != asset.id }.prefix(2)
                updated.source = "generated-turnaround"
                try await ImageConsistencyRepository.shared.saveLook(bookId: book.id, updated)
                await onAccepted(updated)
                await MainActor.run {
                    accepted = true
                    cleanupCandidates()
                    busy = false
                    dismiss()
                }
            } catch {
                await MainActor.run { errorText = error.localizedDescription; busy = false }
            }
        }
    }

    @MainActor
    private func cleanupCandidates() {
        let values = candidates
        candidates.removeAll()
        for item in values { try? FileManager.default.removeItem(atPath: item.imagePath) }
    }
}
