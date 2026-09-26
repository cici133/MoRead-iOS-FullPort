import Foundation

actor BackupRepository {
    static let shared = BackupRepository()
    func test(credentials: WebDAVCredentials) async throws { try await WebDAVClient.shared.test(credentials) }
    func list(credentials: WebDAVCredentials) async throws -> [RemoteBackup] { try await WebDAVClient.shared.list(credentials) }

    func backupToWebDAV(credentials: WebDAVCredentials, mode: BackupMode,
                        onProgress: @Sendable (BackupProgress) -> Void = { _ in }) async throws -> RemoteBackup {
        onProgress(.init(phase: "正在整理备份"))
        let archive = try await BackupArchiveManager.shared.create(mode: mode, onProgress: { p in
            onProgress(.init(phase: p.phase, completedBytes: p.completedBytes, totalBytes: p.totalBytes, percent: p.percent * 35 / 100))
        })
        defer { try? FileManager.default.removeItem(at: archive) }
        let fileSize = Int64(((try? FileManager.default.attributesOfItem(atPath: archive.path)[.size]) as? NSNumber)?.int64Value ?? 0)
        onProgress(.init(phase: "正在上传到 WebDAV", completedBytes: 0, totalBytes: fileSize, percent: 35))
        try await WebDAVClient.shared.upload(credentials, file: archive, remoteName: archive.lastPathComponent) { sent, total in
            let expected = total > 0 ? total : max(fileSize, 1)
            let bounded = max(0, min(sent, expected))
            let transferPercent = Int(bounded * 65 / max(1, expected))
            onProgress(.init(phase: "正在上传到 WebDAV", completedBytes: bounded, totalBytes: expected, percent: 35 + transferPercent))
        }
        onProgress(.init(phase: "备份完成", completedBytes: fileSize, totalBytes: fileSize, percent: 100))
        return .init(name: archive.lastPathComponent, size: fileSize, modifiedAt: Int64(Date().timeIntervalSince1970 * 1000))
    }

    func stageRemoteRestore(credentials: WebDAVCredentials, name: String,
                            onProgress: @Sendable (BackupProgress) -> Void = { _ in }) async throws -> BackupManifest {
        let root = try MoReadDatabase.applicationDirectory().appendingPathComponent("restore", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let temp = root.appendingPathComponent("download.moread.zip.part")
        onProgress(.init(phase: "正在下载远端备份", percent: 0))
        try await WebDAVClient.shared.download(credentials, remoteName: name, to: temp) { received, total in
            let expected = max(total, 1)
            onProgress(.init(phase: "正在下载远端备份", completedBytes: received, totalBytes: total, percent: total > 0 ? Int(min(100, received * 100 / expected)) : 0))
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        onProgress(.init(phase: "正在校验并准备恢复", percent: 100))
        return try await BackupArchiveManager.shared.stageRestore(temp)
    }

    func pruneLightweight(credentials: WebDAVCredentials, keep: Int = 7) async {
        if let list = try? await WebDAVClient.shared.list(credentials) {
            for stale in list.filter({ $0.name.hasPrefix("backup-lite-") }).sorted(by: { $0.modifiedAt > $1.modifiedAt }).dropFirst(keep) {
                try? await WebDAVClient.shared.delete(credentials, remoteName: stale.name)
            }
        }
    }
}
