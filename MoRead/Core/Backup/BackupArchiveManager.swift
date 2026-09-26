import Foundation
import ZIPFoundation

actor BackupArchiveManager {
    static let shared = BackupArchiveManager()
    static let databaseEntry = "database/moread.db"
    static let dataStoreEntry = "datastore/reader_settings.preferences_pb"
    static let manifestEntry = "manifest.json"
    static let lightweightDirectories = ["image-vibes","covers","avatars","reader-custom","image-library"]
    static let managedDirectories = ["image-vibes","books","book-text","book-media","covers","illustrations","attachments","avatars","reader-custom","image-library"]

    func create(mode:BackupMode = .full,onProgress:@Sendable (BackupProgress)->Void={_ in}) async throws->URL{
        let root=try MoReadDatabase.applicationDirectory();let backups=root.appendingPathComponent("backups",isDirectory:true);try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:true)
        let output=backups.appendingPathComponent(Self.fileName(mode:mode));try? FileManager.default.removeItem(at:output)
        let dbURL=try await MoReadDatabase.shared.checkpointForBackup()
        guard let archive=Archive(url:output,accessMode:.create) else{throw BackupError.invalidArchive("无法创建备份文件")}
        let dirs=mode == .full ? Self.managedDirectories:Self.lightweightDirectories
        var sources:[(URL,String)]=[(dbURL,Self.databaseEntry)]
        let settingsBundle=try settingsBundleData();let settingsTemp=backups.appendingPathComponent("settings-\(UUID().uuidString).json");try settingsBundle.write(to:settingsTemp);sources.append((settingsTemp,Self.dataStoreEntry))
        for name in dirs{let dir=root.appendingPathComponent(name,isDirectory:true);guard FileManager.default.fileExists(atPath:dir.path) else{continue};if let e=FileManager.default.enumerator(at:dir,includingPropertiesForKeys:[.isRegularFileKey]){for case let f as URL in e{if (try? f.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true{let rel=f.path.replacingOccurrences(of:dir.path+"/",with:"");sources.append((f,"files/\(name)/\(rel)"))}}}}
        let total=sources.reduce(Int64(0)){sum,p in sum+(((try? FileManager.default.attributesOfItem(atPath:p.0.path)[.size]) as? NSNumber)?.int64Value ?? 0)}.clampedAtLeastOne
        var done:Int64=0
        let manifest=BackupManifest(createdAt:Self.now(),appVersion:"1.2.0-ios-port",databaseVersion:Int(MoReadDatabase.schemaVersion),mode:mode)
        try add(data:try JSONEncoder().encode(manifest),path:Self.manifestEntry,to:archive)
        do{
            for (url,path) in sources{let size=((try? FileManager.default.attributesOfItem(atPath:url.path)[.size]) as? NSNumber)?.int64Value ?? 0;try add(file:url,path:path,to:archive);done+=size;onProgress(.init(phase:mode == .full ? "正在生成完整备份":"正在生成轻量备份",completedBytes:done,totalBytes:total,percent:Int(min(100,done*100/total))))}
            try? FileManager.default.removeItem(at:settingsTemp);onProgress(.init(phase:"备份完成",completedBytes:total,totalBytes:total,percent:100));return output
        }catch{try? FileManager.default.removeItem(at:settingsTemp);try? FileManager.default.removeItem(at:output);throw error}
    }

    func validate(_ file:URL)throws->BackupManifest{
        guard let archive=Archive(url:file,accessMode:.read) else{throw BackupError.invalidArchive("不是有效的 ZIP 备份")}
        var count=0,total:UInt64=0,manifest:BackupManifest?,hasDB=false
        for entry in archive{count+=1;if count>100_000{throw BackupError.invalidArchive("备份文件包含过多条目")};guard Self.safe(entry.path) else{throw BackupError.invalidArchive("备份文件包含非法路径")};total += UInt64(entry.uncompressedSize);if total>16*1024*1024*1024{throw BackupError.invalidArchive("备份文件解压后过大")};if entry.path==Self.databaseEntry{hasDB=true};if entry.path==Self.manifestEntry{var d=Data();_ = try archive.extract(entry){d.append($0)};manifest=try JSONDecoder().decode(BackupManifest.self,from:d)}}
        guard let manifest else{throw BackupError.invalidArchive("不是墨知备份：缺少清单")};guard manifest.formatVersion<=1 else{throw BackupError.invalidArchive("备份格式来自更新版本，请先升级应用")};guard manifest.databaseVersion<=Int(MoReadDatabase.schemaVersion) else{throw BackupError.invalidArchive("数据库来自更新版本，请先升级应用")};guard manifest.packageName=="com.mozhi.reader" else{throw BackupError.invalidArchive("备份不属于墨知")};guard hasDB else{throw BackupError.invalidArchive("备份缺少数据库")};return manifest
    }

    func stageRestore(_ file:URL)throws->BackupManifest{
        let manifest=try validate(file);let root=try MoReadDatabase.applicationDirectory().appendingPathComponent("restore",isDirectory:true);let preparing=root.appendingPathComponent("prepared.part",isDirectory:true),prepared=root.appendingPathComponent("prepared",isDirectory:true);try? FileManager.default.removeItem(at:preparing);try FileManager.default.createDirectory(at:preparing,withIntermediateDirectories:true)
        guard let archive=Archive(url:file,accessMode:.read) else{throw BackupError.invalidArchive("恢复包无效")}
        for entry in archive where entry.type != .directory{guard Self.safe(entry.path) else{throw BackupError.invalidArchive("恢复包路径非法")};let target=preparing.appendingPathComponent(entry.path).standardizedFileURL;guard target.path.hasPrefix(preparing.standardizedFileURL.path) else{throw BackupError.invalidArchive("恢复包路径越界")};try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true);_ = try archive.extract(entry,to:target)}
        guard FileManager.default.fileExists(atPath:preparing.appendingPathComponent(Self.databaseEntry).path) else{throw BackupError.invalidArchive("恢复包缺少数据库")};try? FileManager.default.removeItem(at:prepared);try FileManager.default.moveItem(at:preparing,to:prepared);return manifest
    }

    static func applyPendingRestore() throws {
        let app=try MoReadDatabase.applicationDirectory(),prepared=app.appendingPathComponent("restore/prepared",isDirectory:true);guard FileManager.default.fileExists(atPath:prepared.path) else{return}
        let dbSource=prepared.appendingPathComponent(databaseEntry),dbTarget=app.appendingPathComponent("moread.db");guard FileManager.default.fileExists(atPath:dbSource.path) else{return}
        for suffix in ["","-wal","-shm"]{try? FileManager.default.removeItem(at:URL(fileURLWithPath:dbTarget.path+suffix))}
        try FileManager.default.copyItem(at:dbSource,to:dbTarget)
        for name in managedDirectories{let source=prepared.appendingPathComponent("files/\(name)",isDirectory:true);if FileManager.default.fileExists(atPath:source.path){let target=app.appendingPathComponent(name,isDirectory:true);try? FileManager.default.removeItem(at:target);try FileManager.default.copyItem(at:source,to:target)}}
        let settings=prepared.appendingPathComponent(dataStoreEntry);if let data=try? Data(contentsOf:settings){try applySettingsBundle(data,root:app)}
        try? FileManager.default.removeItem(at:prepared)
    }

    private func settingsBundleData() throws -> Data {
        let root = try MoReadDatabase.applicationDirectory()
        let fileNames = [
            "reader-settings.json", "reader-enhancements.json", "backup-settings.json",
            "ios-compat-settings.json", "tts-settings.json", "image-api-settings.json",
            "web-search-settings.json", "companion-autonomy.json",
            "proactive-annotation-settings.json", "proactive-annotation-quota.json",
            "user-masks.json", "global-prompt-presets.json",
            "memory.plist"
        ]
        var files: [String: String] = [:]
        for name in fileNames {
            let url = root.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) { files[name] = data.base64EncodedString() }
        }
        let defaults = UserDefaults.standard
        let defaultKeys = ["app.color.mode", "app.language", "app.palette", "app.accent.hex", "app.surface.style", "app.nav.style", "app.shape.density", "app.font.postscript", "stats.visible.cards", "moread.review.share.templates.v1", "shelf.book.order", "shelf.book.order.read.anchor", "shelf.reading.order.affects"]
        var userDefaults: [String: [String: String]] = [:]
        for key in defaultKeys {
            if let value = defaults.string(forKey: key) { userDefaults[key] = ["type":"string", "value":value] }
            else if let value = defaults.data(forKey: key) { userDefaults[key] = ["type":"data", "value":value.base64EncodedString()] }
        }
        return try JSONSerialization.data(withJSONObject: [
            "format":"moread-ios-settings-v2",
            "files":files,
            "user_defaults":userDefaults
        ])
    }

    private static func applySettingsBundle(_ data: Data, root: URL) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let files = object["files"] as? [String: String] {
            for (name, encoded) in files where !name.contains("/") && !name.contains("..") {
                if let value = Data(base64Encoded: encoded) { try value.write(to: root.appendingPathComponent(name), options: .atomic) }
            }
        }
        if let saved = object["user_defaults"] as? [String: [String: String]] {
            let allowed = Set(["app.color.mode", "app.language", "app.palette", "app.accent.hex", "app.surface.style", "app.nav.style", "app.shape.density", "app.font.postscript", "stats.visible.cards", "moread.review.share.templates.v1", "shelf.book.order", "shelf.book.order.read.anchor", "shelf.reading.order.affects"])
            for (key, row) in saved where allowed.contains(key) {
                if row["type"] == "string", let value = row["value"] { UserDefaults.standard.set(value, forKey: key) }
                else if row["type"] == "data", let encoded = row["value"], let value = Data(base64Encoded: encoded) { UserDefaults.standard.set(value, forKey: key) }
            }
        }
    }
    private func add(data:Data,path:String,to archive:Archive)throws{try archive.addEntry(with:path,type:.file,uncompressedSize:UInt32(data.count),compressionMethod:.deflate){position,size in let a=Int(position),b=min(data.count,a+size);return data.subdata(in:a..<b)}}
    private func add(file:URL,path:String,to archive:Archive)throws{let size=((try FileManager.default.attributesOfItem(atPath:file.path)[.size]) as? NSNumber)?.uint64Value ?? 0;let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()};try archive.addEntry(with:path,type:.file,uncompressedSize:UInt32(clamping:size),compressionMethod:.deflate){position,count in try handle.seek(toOffset: UInt64(position));return try handle.read(upToCount:count) ?? Data()}}
    private static func safe(_ name:String)->Bool{if name.isEmpty||name.hasPrefix("/")||name.hasPrefix("\\"){return false};let n=name.replacingOccurrences(of:"\\",with:"/");if n.split(separator:"/").contains(".."){return false};return n==manifestEntry||n==databaseEntry||n==dataStoreEntry||n.hasPrefix("files/")}
    private static func fileName(mode:BackupMode)->String{let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.dateFormat="yyyyMMdd-HHmmss";return "backup-\(mode == .full ? "full":"lite")-\(f.string(from:Date()))\(WebDAVClient.backupExtension)"}
    private static func now()->Int64{Int64(Date().timeIntervalSince1970*1000)}
}
private extension Int64 { var clampedAtLeastOne: Int64 { Swift.max(Int64(1), self) } }
