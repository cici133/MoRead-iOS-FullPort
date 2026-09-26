import BackgroundTasks
import Foundation

@MainActor
enum BackupBackgroundScheduler {
    static var refreshIdentifier: String { (Bundle.main.bundleIdentifier ?? "com.mozhi.reader.ios") + ".refresh" }
    static var processingIdentifier: String { (Bundle.main.bundleIdentifier ?? "com.mozhi.reader.ios") + ".processing" }

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            handle(task)
        }
    }

    static func update(enabled: Bool) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingIdentifier)
        guard enabled else { return }
        scheduleNext()
    }

    /// Re-establish a persisted automatic-backup request after app launch or a staged restore.
    /// BGTask requests are system-managed and may disappear after reinstall/restore, so the saved
    /// preference is the source of truth, not the existence of a previously submitted request.
    static func resumeStoredPreference() {
        guard let root = try? MoReadDatabase.applicationDirectory(),
              let data = try? Data(contentsOf: root.appendingPathComponent("backup-settings.json")),
              let settings = try? JSONDecoder().decode(BackupSettings.self, from: data) else { return }
        update(enabled: settings.autoBackup && settings.configured)
    }

    static func scheduleNext() {
        let request = BGProcessingTaskRequest(identifier: processingIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            updateLedger { $0.lastBackgroundScheduleAt = now() }
        } catch {
            updateLedger { $0.lastAutoBackupError = "后台任务提交失败：\(error.localizedDescription)" }
        }
    }

    private static func handle(_ task: BGProcessingTask) {
        scheduleNext()
        let worker = Task {
            updateLedger { $0.lastAutoBackupAttemptAt = now(); $0.lastAutoBackupError = nil }
            do {
                guard let credentials = credentialsSnapshot(), credentials.autoBackup else { task.setTaskCompleted(success: true); return }
                _ = try await BackupRepository.shared.backupToWebDAV(credentials: credentials.credentials, mode: .lightweight)
                await BackupRepository.shared.pruneLightweight(credentials: credentials.credentials)
                markBackupSuccess()
                task.setTaskCompleted(success: true)
            } catch {
                updateLedger { $0.lastAutoBackupError = String(error.localizedDescription.prefix(600)) }
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { worker.cancel() }
    }

    private struct Snapshot { var credentials: WebDAVCredentials; var autoBackup: Bool }
    private static func credentialsSnapshot() -> Snapshot? {
        guard let root=try? MoReadDatabase.applicationDirectory(),let data=try? Data(contentsOf:root.appendingPathComponent("backup-settings.json")),let settings=try? JSONDecoder().decode(BackupSettings.self,from:data),settings.configured else{return nil}
        let password=KeychainStore.get(account:BackupSettingsStore.passwordAlias);guard !password.isEmpty else{return nil}
        return .init(credentials:.init(baseURL:settings.webDAVURL,username:settings.username,password:password,remoteDirectory:settings.remoteDirectory),autoBackup:settings.autoBackup)
    }
    private static func markBackupSuccess() { updateLedger { value in let stamp = now(); value.lastBackupAt = stamp; value.lastAutoBackupAt = stamp; value.lastAutoBackupError = nil } }
    private static func updateLedger(_ change: (inout BackupSettings) -> Void) {
        guard let root = try? MoReadDatabase.applicationDirectory() else { return }
        let url = root.appendingPathComponent("backup-settings.json")
        var value = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(BackupSettings.self, from: $0) } ?? BackupSettings()
        change(&value)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
    }
    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
