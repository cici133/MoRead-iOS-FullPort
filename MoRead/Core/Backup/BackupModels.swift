import Foundation

enum BackupMode: String, Codable, CaseIterable, Sendable { case lightweight = "LIGHTWEIGHT"; case full = "FULL" }
struct BackupManifest: Codable, Sendable {
    var formatVersion = 1
    var createdAt: Int64
    var appVersion: String
    var databaseVersion: Int
    var packageName = "com.mozhi.reader"
    var mode: BackupMode = .full
}
struct BackupProgress: Sendable { var phase: String; var completedBytes: Int64 = 0; var totalBytes: Int64 = 0; var percent: Int = 0 }
struct RemoteBackup: Identifiable, Hashable, Sendable { var id: String { name }; var name: String; var size: Int64; var modifiedAt: Int64 }
struct WebDAVCredentials: Codable, Sendable { var baseURL: String; var username: String; var password: String; var remoteDirectory: String }
struct BackupSettings: Codable, Equatable, Sendable {
    var webDAVURL = ""; var username = ""; var remoteDirectory = "MoRead"; var autoBackup = false; var lastBackupAt: Int64 = 0
    // Optional for backward compatibility with settings written by earlier iOS-port builds.
    var lastAutoBackupAttemptAt: Int64? = nil
    var lastAutoBackupAt: Int64? = nil
    var lastAutoBackupError: String? = nil
    var lastBackgroundScheduleAt: Int64? = nil
    var configured: Bool { !webDAVURL.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !username.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
}

@MainActor final class BackupSettingsStore: ObservableObject {
    static let shared = BackupSettingsStore()
    @Published var settings: BackupSettings { didSet { saveLocal() } }
    @Published var password = "" { didSet { if !password.isEmpty { KeychainStore.set(password, account: Self.passwordAlias) } } }
    static let passwordAlias = "webdav-password"
    private let url: URL
    init() {
        let root=(try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory
        url=root.appendingPathComponent("backup-settings.json")
        settings=(try? Data(contentsOf:url)).flatMap{try? JSONDecoder().decode(BackupSettings.self,from:$0)} ?? BackupSettings()
        password=KeychainStore.get(account:Self.passwordAlias)
    }
    func credentials() throws -> WebDAVCredentials {
        guard settings.configured else { throw BackupError.invalidConfiguration("请先配置 WebDAV") }
        guard !password.isEmpty else { throw BackupError.invalidConfiguration("请保存 WebDAV 密码或应用专用密码") }
        return .init(baseURL:settings.webDAVURL,username:settings.username,password:password,remoteDirectory:settings.remoteDirectory.isEmpty ? "MoRead":settings.remoteDirectory)
    }
    func markBackup(){settings.lastBackupAt=Int64(Date().timeIntervalSince1970*1000)}
    func reload() { if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(BackupSettings.self, from: data) { settings = value } }
    private func saveLocal(){try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);if let d=try? JSONEncoder().encode(settings){try? d.write(to:url,options:.atomic)}}
}

enum BackupError: LocalizedError {
    case invalidConfiguration(String), invalidArchive(String), network(String), restoreRequiresRestart
    var errorDescription:String?{switch self{case .invalidConfiguration(let s),.invalidArchive(let s),.network(let s):return s;case .restoreRequiresRestart:return "恢复数据已准备好，请重启应用完成恢复"}}
}
