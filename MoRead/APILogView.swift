import SwiftUI

struct APILogView: View {
    @ObservedObject private var store = APICallLogStore.shared
    var body: some View {
        List {
            Section {
                Toggle("记录 API 调用", isOn: $store.enabled)
                Text("只记录接口地址、方法、状态码、耗时与字节数；不会记录 API Key、Authorization、书籍正文、提示词或模型回复正文。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("清空日志", role: .destructive) { store.clear() }.disabled(store.entries.isEmpty)
            }
            Section(header: Text("最近调用")) {
                if store.entries.isEmpty { ContentUnavailableView("暂无日志", systemImage: "list.bullet.rectangle") }
                ForEach(store.entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.category).font(.caption).padding(.horizontal,6).padding(.vertical,2).background(.thinMaterial,in:Capsule())
                            Text(entry.method).font(.caption.monospaced())
                            Spacer()
                            if let status = entry.statusCode { Text("HTTP \(status)").font(.caption.monospaced()).foregroundStyle(status < 400 ? .secondary : .red) }
                        }
                        Text(entry.url).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                        HStack {
                            Text("\(entry.durationMs) ms")
                            Text("↑ \(ByteCountFormatter.string(fromByteCount: Int64(entry.requestBytes), countStyle: .memory))")
                            Text("↓ \(ByteCountFormatter.string(fromByteCount: Int64(entry.responseBytes), countStyle: .memory))")
                            Spacer(); Text(entry.startedAt, style: .time)
                        }.font(.caption2).foregroundStyle(.secondary)
                        if let error = entry.errorType { Text(error).font(.caption2).foregroundStyle(.red) }
                    }.padding(.vertical,3)
                }
            }
        }
        .navigationTitle("API 调用日志")
    }
}
