import SwiftUI

struct DiagnosticsView: View {
    @State private var snapshot: DiagnosticSnapshot?
    @State private var loading = false
    @State private var reportURL: URL?
    @State private var updateStatus: AppUpdateStatus?
    @State private var checkingUpdate = false
    var body: some View {
        List {
            Section {
                Button { Task { await run() } } label: {
                    HStack { if loading { ProgressView().controlSize(.small) }; Text("运行诊断") }
                }.disabled(loading)
                if let reportURL { ShareLink(item: reportURL) { Label("分享诊断报告", systemImage: "square.and.arrow.up") } }
                Text("诊断只检查数据库、文件、配置与系统任务状态，不读取或导出书籍正文、聊天正文、API Key 或 Authorization。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let snapshot {
                Section("检查结果") {
                    ForEach(snapshot.checks) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon(item.level)).foregroundStyle(color(item.level))
                            VStack(alignment: .leading, spacing: 4) { Text(item.title).font(.headline); Text(item.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }.padding(.vertical, 3)
                    }
                }
            }
            Section("版本与更新") {
                LabeledContent("当前版本", value: updateStatus?.currentVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
                if let latest = updateStatus?.latestVersion {
                    LabeledContent("最新 Release", value: latest)
                    if updateStatus?.updateAvailable == true {
                        Label("发现新版本", systemImage: "arrow.down.circle.fill").foregroundStyle(.tint)
                    } else {
                        Label("当前已是最新版本", systemImage: "checkmark.circle")
                    }
                }
                if let error = updateStatus?.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                Button { Task { await checkUpdate() } } label: {
                    HStack { if checkingUpdate { ProgressView().controlSize(.small) }; Text("检查 GitHub Release") }
                }.disabled(checkingUpdate)
                if let url = updateStatus?.releaseURL { Link("打开 Release 页面", destination: url) }
                Text("自签 IPA 无法像 App Store 应用一样静默覆盖安装；这里保持 Android 版的更新检查能力，发现新版本后打开官方 Release/源码页面，由你重新构建并自签。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("平台适配说明") {
                Text("iOS 不允许第三方应用枚举其他 TTS App 或全局拦截实体音量键；对应功能使用 AVSpeechSynthesizer / 云 TTS、MPRemoteCommandCenter 与外接键盘按键实现。后台自动备份由 iOS BGTaskScheduler 调度，系统不保证精确时刻。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于与诊断")
        .task {
            if snapshot == nil { await run() }
            if updateStatus == nil { await checkUpdate() }
        }
    }

    @MainActor private func run() async {
        loading = true
        let value = await DiagnosticsService.shared.run(); snapshot = value
        if let root = try? MoReadDatabase.applicationDirectory() {
            let dir = root.appendingPathComponent("exports", isDirectory: true); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("MoRead-diagnostics.txt")
            try? value.report.data(using: .utf8)?.write(to: url, options: .atomic); reportURL = url
        }
        loading = false
    }

    @MainActor private func checkUpdate() async {
        checkingUpdate = true
        updateStatus = await AppUpdateService.shared.check()
        checkingUpdate = false
    }
    private func icon(_ level: DiagnosticCheck.Level) -> String { switch level { case .ok: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .error: "xmark.octagon.fill" } }
    private func color(_ level: DiagnosticCheck.Level) -> Color { switch level { case .ok: .green; case .warning: .orange; case .error: .red } }
}
