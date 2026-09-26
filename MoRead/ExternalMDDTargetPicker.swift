import SwiftUI

struct ExternalMDDTargetPicker: View {
    let pending: PendingExternalMDD
    @ObservedObject private var coordinator = ExternalOpenCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var dictionaries: [LocalDictionary] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("资源文件", value: pending.name)
                    Text("MDD 是 MDX 词典的资源包，必须附加到一个已有词典。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("选择目标词典") {
                    if loading { ProgressView() }
                    else if dictionaries.isEmpty {
                        ContentUnavailableView("还没有 MDX 词典", systemImage: "character.book.closed", description: Text("请先在 设置 → 本地词典 导入 MDX，然后再次打开这个 MDD。"))
                    } else {
                        ForEach(dictionaries) { dictionary in
                            Button {
                                Task { await coordinator.finishMDDImport(dictionaryId: dictionary.id); dismiss() }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(dictionary.title)
                                        Text("已有 \(dictionary.resourceCount) 个 MDD 资源包")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName: "chevron.right")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加 MDD 资源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { coordinator.cancelMDDImport(); dismiss() }
                }
            }
            .task {
                dictionaries = (try? await LocalDictionaryRepository.shared.list()) ?? []
                loading = false
            }
        }
    }
}
