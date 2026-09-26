import Foundation
import CryptoKit

actor LocalDictionaryRepository {
    static let shared = LocalDictionaryRepository()
    private var readers: [String: MdictReader] = [:]
    private var lru: [String] = []

    private var root: URL {
        get throws {
            let url = try MoReadDatabase.applicationDirectory().appendingPathComponent("reader-custom/dictionaries", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    func list() throws -> [LocalDictionary] {
        let fm = FileManager.default
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && fm.fileExists(atPath: $0.appendingPathComponent("main.mdx").path) }
            .map(descriptor)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    func importMdx(from url: URL) throws -> (dictionary: LocalDictionary, duplicate: Bool) {
        guard url.pathExtension.caseInsensitiveCompare("mdx") == .orderedSame else { throw DictionaryError.invalid("请选择 MDX 词典文件") }
        let stagingRoot = try root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staging = stagingRoot.appendingPathComponent("importing")
        do {
            try boundedCopy(url, staging, maxBytes: 4 * 1024 * 1024 * 1024)
            let fp = try fingerprint(staging)
            for existing in try list() {
                let dir = try root.appendingPathComponent(existing.id, isDirectory: true)
                let mdx = dir.appendingPathComponent("main.mdx")
                if try fingerprint(mdx) == fp {
                    try? url.lastPathComponent.write(to: dir.appendingPathComponent("source-name.txt"), atomically: true, encoding: .utf8)
                    try? FileManager.default.removeItem(at: stagingRoot)
                    return (existing, true)
                }
            }
            let reader = try MdictReader(url: staging)
            let title = reader.declaredTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url.deletingPathExtension().lastPathComponent : reader.declaredTitle
            try url.lastPathComponent.write(to: stagingRoot.appendingPathComponent("source-name.txt"), atomically: true, encoding: .utf8)
            try title.write(to: stagingRoot.appendingPathComponent("title.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.moveItem(at: staging, to: stagingRoot.appendingPathComponent("main.mdx"))
            return (.init(id: stagingRoot.lastPathComponent, title: title, resourceCount: 0, enabled: true), false)
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw error
        }
    }

    func importResources(dictionaryId: String, urls: [URL]) throws -> (imported: Int, duplicates: Int) {
        let dir = try directory(dictionaryId)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("main.mdx").path) else { throw DictionaryError.invalid("请先导入 MDX 词典") }
        var imported = 0, duplicates = 0
        var known = Set<String>()
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension.lowercased() == "mdd" {
            known.insert(try fingerprint(file))
        }
        for source in urls {
            guard source.pathExtension.caseInsensitiveCompare("mdd") == .orderedSame else { throw DictionaryError.invalid("资源文件必须是 MDD") }
            let temp = dir.appendingPathComponent(UUID().uuidString + ".tmp")
            defer { try? FileManager.default.removeItem(at: temp) }
            try boundedCopy(source, temp, maxBytes: 4 * 1024 * 1024 * 1024)
            let fp = try fingerprint(temp)
            if known.contains(fp) { duplicates += 1; continue }
            _ = try MdictReader(url: temp, resource: true)
            let target = dir.appendingPathComponent(UUID().uuidString + ".mdd")
            try FileManager.default.moveItem(at: temp, to: target)
            known.insert(fp); imported += 1
        }
        return (imported, duplicates)
    }

    func delete(_ id: String) throws {
        let dir = try directory(id)
        readers.keys.filter { $0.hasPrefix(dir.path + "/") }.forEach { readers.removeValue(forKey: $0) }
        lru.removeAll { $0.hasPrefix(dir.path + "/") }
        try FileManager.default.removeItem(at: dir)
    }

    func setEnabled(_ id: String, enabled: Bool) throws {
        let dir = try directory(id)
        let marker = dir.appendingPathComponent("disabled")
        if enabled { try? FileManager.default.removeItem(at: marker) }
        else if !FileManager.default.fileExists(atPath: marker.path) { FileManager.default.createFile(atPath: marker.path, contents: Data()) }
    }

    func lookup(_ word: String) throws -> [DictionaryDefinition] {
        var result: [DictionaryDefinition] = []
        for dict in try list() where dict.enabled {
            let mdx = try directory(dict.id).appendingPathComponent("main.mdx")
            if let html = try reader(mdx).definition(word) { result.append(.init(dictionaryId: dict.id, title: dict.title, html: html)) }
        }
        return result
    }

    func resource(dictionaryId: String, path: String) throws -> Data? {
        let dir = try directory(dictionaryId)
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension.lowercased() == "mdd" {
            if let data = try reader(file).lookup(path) { return data }
        }
        return nil
    }

    private func descriptor(_ dir: URL) -> LocalDictionary {
        let titleURL = dir.appendingPathComponent("title.txt")
        let sourceURL = dir.appendingPathComponent("source-name.txt")
        let title = ((try? String(contentsOf: titleURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (try? String(contentsOf: sourceURL, encoding: .utf8)).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? dir.lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return .init(id: dir.lastPathComponent, title: title, resourceCount: files.filter { $0.pathExtension.lowercased() == "mdd" }.count, enabled: !FileManager.default.fileExists(atPath: dir.appendingPathComponent("disabled").path))
    }

    private func directory(_ id: String) throws -> URL {
        guard !id.isEmpty, !id.contains("/"), !id.contains("..") else { throw DictionaryError.invalid("词典 ID 无效") }
        return try root.appendingPathComponent(id, isDirectory: true)
    }

    private func reader(_ url: URL) throws -> MdictReader {
        if let cached = readers[url.path] { touch(url.path); return cached }
        let value = try MdictReader(url: url)
        readers[url.path] = value; touch(url.path)
        while lru.count > 6, let old = lru.first { lru.removeFirst(); readers.removeValue(forKey: old) }
        return value
    }
    private func touch(_ path: String) { lru.removeAll { $0 == path }; lru.append(path) }

    private func boundedCopy(_ source: URL, _ target: URL, maxBytes: Int64) throws {
        let input = try FileHandle(forReadingFrom: source)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? input.close(); try? output.close() }
        var total: Int64 = 0
        while true {
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            total += Int64(chunk.count); guard total <= maxBytes else { throw DictionaryError.invalid("词典文件过大") }
            try output.write(contentsOf: chunk)
        }
    }
    private func fingerprint(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while true { let d = try handle.read(upToCount: 1024 * 1024) ?? Data(); if d.isEmpty { break }; hash.update(data: d) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    struct DictionaryError: LocalizedError { let message:String; static func invalid(_ s:String)->Self{.init(message:s)}; var errorDescription:String?{message} }
}

actor VocabularyRepository {
    static let shared = VocabularyRepository()
    private var url: URL { get throws { try MoReadDatabase.applicationDirectory().appendingPathComponent("reader-custom/vocabulary.json") } }
    func list() throws -> [VocabularyEntry] { try load().sorted { $0.updatedAt > $1.updatedAt } }
    func save(_ entry: VocabularyEntry) throws { var all=try load();all.removeAll{$0.word.caseInsensitiveCompare(entry.word) == .orderedSame};all.append(entry);try persist(all) }
    func remove(word:String)throws{var all=try load();all.removeAll{$0.word.caseInsensitiveCompare(word) == .orderedSame};try persist(all)}
    func setLearned(word:String,learned:Bool)throws{var all=try load();if let i=all.firstIndex(where:{$0.word.caseInsensitiveCompare(word) == .orderedSame}){all[i].learned=learned;all[i].updatedAt=Self.now()};try persist(all)}
    private func load()throws->[VocabularyEntry]{let u=try url;guard let data=try? Data(contentsOf:u) else{return []};return (try? JSONDecoder().decode([VocabularyEntry].self,from:data)) ?? []}
    private func persist(_ values:[VocabularyEntry])throws{let u=try url;try FileManager.default.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONEncoder().encode(values).write(to:u,options:.atomic)}
    static func now()->Int64{Int64(Date().timeIntervalSince1970*1000)}
}
