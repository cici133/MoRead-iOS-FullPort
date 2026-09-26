import SwiftUI

struct TextCleanupView: View {
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var enhancements = ReaderEnhancementSettingsStore.shared
    @State private var preview: LibraryRepository.TextCleanupPreview?
    @State private var busy = false
    @State private var confirm = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section("将永久应用的规则") {
                    let active = enhancements.settings.replacementRules.filter { $0.enabled && !$0.forListenOnly }
                    if active.isEmpty { Text("没有启用的正文规则").foregroundStyle(.secondary) }
                    ForEach(active) { rule in VStack(alignment:.leading){Text(rule.name);Text(rule.pattern).font(.caption).foregroundStyle(.secondary).lineLimit(2)} }
                }
                if let preview {
                    Section("预览") {
                        LabeledContent("命中", value: "\(preview.matchCount) 处")
                        LabeledContent("变化章节", value: "\(preview.changedChapters) 章")
                    }
                    ForEach(preview.examples) { row in
                        Section("第 \(row.chapterIndex + 1) 章 · \(row.title)") {
                            VStack(alignment:.leading,spacing:5){Text("原文").font(.caption.bold());Text(row.before).font(.caption).lineLimit(6)}
                            VStack(alignment:.leading,spacing:5){Text("应用后").font(.caption.bold());Text(row.after).font(.caption).lineLimit(6)}
                        }
                    }
                }
            }
            .navigationTitle("永久应用正文净化")
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button("关闭"){dismiss()}}
                ToolbarItemGroup(placement:.confirmationAction){
                    Button("预览"){Task{await loadPreview()}}.disabled(busy)
                    Button("应用"){confirm=true}.disabled(preview == nil || busy)
                }
            }
            .task { await loadPreview() }
            .alert("永久修改正文？",isPresented:$confirm){Button("取消",role:.cancel){};Button("确认应用",role:.destructive){Task{await apply()}}} message:{Text("这会重写本书规范正文并重置阅读位置、向量索引和有声书缓存状态。已有批注/笔记不会被删除，但因文本发生变化，旧坐标可能需要重新定位。")}
            .alert("提示",isPresented:Binding(get:{message != nil},set:{if !$0{message=nil}})){Button("好",role:.cancel){}}message:{Text(message ?? "")}
        }
    }
    @MainActor private func loadPreview() async {busy=true;defer{busy=false};do{preview=try await LibraryRepository.shared.previewTextCleanup(bookId:book.id,rules:enhancements.settings.replacementRules)}catch{message=error.localizedDescription}}
    @MainActor private func apply() async {guard let preview else{return};busy=true;defer{busy=false};do{let count=try await LibraryRepository.shared.applyTextCleanup(bookId:book.id,rules:enhancements.settings.replacementRules,expectedRevision:preview.revision);message="已永久应用 \(count) 处替换";self.preview=nil}catch{message=error.localizedDescription}}
}
