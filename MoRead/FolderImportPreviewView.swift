import SwiftUI

struct FolderImportPreviewView: View {
    let session: FolderImportSession
    var onImport: ([URL]) -> Void
    var onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var query = ""

    private var filtered: [FolderBookCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return session.candidates }
        return session.candidates.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.relativeDirectory.localizedCaseInsensitiveContains(q)
        }
    }
    private var groups: [(String, [FolderBookCandidate])] {
        Dictionary(grouping: filtered, by: \.relativeDirectory)
            .map { ($0.key, $0.value) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if session.candidates.count >= FolderImportScanner.maxFiles {
                    Section { Text("已达到扫描上限 \(FolderImportScanner.maxFiles) 本；更深或后续文件未继续扫描。") .font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(groups, id: \.0) { directory, files in
                    Section(directory.isEmpty ? "根目录" : directory) {
                        ForEach(files) { file in
                            Button { toggle(file) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(file.id) ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(file.name).foregroundStyle(file.looksImported ? .secondary : .primary)
                                        HStack(spacing: 8) {
                                            Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file))
                                            if file.looksImported { Text("可能已导入").foregroundStyle(.orange) }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(file.url.pathExtension.uppercased()).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索文件名或目录")
            .navigationTitle("扫描到 \(session.candidates.count) 本")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel(); dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(selected.count == session.candidates.count && !session.candidates.isEmpty ? "取消全选" : "全选") {
                        if selected.count == session.candidates.count { selected.removeAll() }
                        else { selected = Set(session.candidates.map(\.id)) }
                    }
                    Button("导入 \(selected.count) 本") {
                        let urls = session.candidates.filter { selected.contains($0.id) }.map(\.url)
                        onImport(urls)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .onAppear { selected = Set(session.candidates.map(\.id)) }
        }
    }

    private func toggle(_ file: FolderBookCandidate) {
        if !selected.insert(file.id).inserted { selected.remove(file.id) }
    }
}
