import CryptoKit
import Foundation
import ZIPFoundation

struct ChapterTextRange: Equatable, Sendable {
    let index: Int
    let byteOffset: Int64
    let byteLength: Int
    let charCount: Int // UTF-16 code units, matching Android String.length
}

struct ChapterTextInput: Sendable { let index: Int; let body: String }

enum BookTextError: LocalizedError {
    case sourceMissing, incomplete, invalidUTF8, tooLarge, corruptArchive
    var errorDescription: String? {
        switch self {
        case .sourceMissing: return "规范正文尚未就绪或已缺失"
        case .incomplete: return "章节正文不完整"
        case .invalidUTF8: return "章节 UTF-8 解析失败"
        case .tooLarge: return "正文超过本地读取上限"
        case .corruptArchive: return "正文压缩索引损坏"
        }
    }
}

/// Same observable contract as Android BookTextWriter/BookTextArchive: chapter DB offsets address
/// the decoded UTF-8 stream while reading positions address UTF-16 code units.
actor BookTextStore {
    static let shared = BookTextStore()
    static let blockBytes = 64 * 1024
    private let decodedCacheLimit = 3
    private var cache: [CacheKey: String] = [:]
    private var cacheOrder: [CacheKey] = []

    private struct CacheKey: Hashable { let bookId: Int64; let offset: Int64; let length: Int }

    func bookDirectory(_ bookId: Int64) throws -> URL {
        let root = try MoReadDatabase.applicationDirectory().appendingPathComponent("book-text", isDirectory: true)
        let directory = root.appendingPathComponent(String(bookId), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func textFile(_ bookId: Int64) throws -> URL { try bookDirectory(bookId).appendingPathComponent("text.mz") }

    func write(bookId: Int64, chapters: [ChapterTextInput]) throws -> [ChapterTextRange] {
        let target = try textFile(bookId)
        let temp = target.deletingLastPathComponent().appendingPathComponent("text-write-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        var ranges: [ChapterTextRange] = []
        var offset: Int64 = 0
        do {
            for chapter in chapters.sorted(by: { $0.index < $1.index }) {
                let body = Self.normalize(chapter.body)
                let data = Data(body.utf8)
                try handle.write(contentsOf: data)
                ranges.append(.init(index: chapter.index, byteOffset: offset, byteLength: data.count, charCount: body.utf16.count))
                offset += Int64(data.count)
            }
            try handle.close()
            _ = try compactIfUseful(file: temp)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temp, to: target)
            invalidate(bookId: bookId)
            return ranges
        } catch {
            try? handle.close(); try? FileManager.default.removeItem(at: temp); throw error
        }
    }

    func readChapter(bookId: Int64, byteOffset: Int64, byteLength: Int) throws -> String {
        guard byteOffset >= 0, byteLength >= 0 else { throw BookTextError.incomplete }
        let key = CacheKey(bookId: bookId, offset: byteOffset, length: byteLength)
        if let value = cache[key] { touch(key); return value }
        let data = try readBytes(file: textFile(bookId), offset: byteOffset, size: byteLength)
        guard let text = String(data: data, encoding: .utf8) else { throw BookTextError.invalidUTF8 }
        cache[key] = text; touch(key); trimCache()
        return text
    }

    func contentRevision(bookId: Int64) throws -> String {
        let file = try textFile(bookId)
        guard FileManager.default.fileExists(atPath: file.path) else { throw BookTextError.sourceMissing }
        var hash = SHA256()
        if try isZip(file) {
            guard let archive = Archive(url: file, accessMode: .read), let meta = archive["moread-text-v1"] else { throw BookTextError.corruptArchive }
            var metaData = Data(); _ = try archive.extract(meta) { metaData.append($0) }
            guard let metaText = String(data: metaData, encoding: .ascii), let total = Int64(metaText.split(separator: ":").last ?? "") else { throw BookTextError.corruptArchive }
            let count = Int((total + Int64(Self.blockBytes) - 1) / Int64(Self.blockBytes))
            for index in 0..<count {
                guard let entry = archive["text/\(index)"] else { throw BookTextError.corruptArchive }
                var data = Data(); _ = try archive.extract(entry) { data.append($0) }; hash.update(data: data)
            }
        } else {
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            while let data = try handle.read(upToCount: Self.blockBytes), !data.isEmpty { hash.update(data: data) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func delete(bookId: Int64) throws {
        let directory = try bookDirectory(bookId)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        invalidate(bookId: bookId)
    }

    func invalidate(bookId: Int64) {
        cache.keys.filter { $0.bookId == bookId }.forEach { cache.removeValue(forKey: $0) }
        cacheOrder.removeAll { $0.bookId == bookId }
    }

    static func normalize(_ body: String) -> String {
        let unified = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\t", with: " ")
        var output: [String] = []
        var pendingBlank = false
        for raw in unified.components(separatedBy: "\n") {
            let line = raw.trimmingLeadingCharacters(in: CharacterSet(charactersIn: " \u{00A0}\u{3000}")).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if !output.isEmpty { pendingBlank = true }; continue }
            if pendingBlank { output.append(""); pendingBlank = false }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    private func readBytes(file: URL, offset: Int64, size: Int) throws -> Data {
        guard FileManager.default.fileExists(atPath: file.path) else { throw BookTextError.sourceMissing }
        if try isZip(file) {
            guard let archive = Archive(url: file, accessMode: .read), let meta = archive["moread-text-v1"] else { throw BookTextError.corruptArchive }
            var metaData = Data(); _ = try archive.extract(meta) { metaData.append($0) }
            guard let metaText = String(data: metaData, encoding: .ascii) else { throw BookTextError.corruptArchive }
            let parts = metaText.split(separator: ":")
            guard parts.count == 2, Int(parts[0]) == Self.blockBytes, let length = Int64(parts[1]), offset <= length, Int64(size) <= length - offset else { throw BookTextError.incomplete }
            var result = Data(); result.reserveCapacity(size)
            var copied = 0
            while copied < size {
                let position = offset + Int64(copied)
                let blockIndex = Int(position / Int64(Self.blockBytes))
                let start = Int(position % Int64(Self.blockBytes))
                guard let entry = archive["text/\(blockIndex)"] else { throw BookTextError.corruptArchive }
                var block = Data(); _ = try archive.extract(entry) { block.append($0) }
                let count = min(block.count - start, size - copied)
                guard count >= 0, start <= block.count else { throw BookTextError.incomplete }
                result.append(block.subdata(in: start..<(start + count)))
                copied += count
            }
            return result
        }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: size), data.count == size else { throw BookTextError.incomplete }
        return data
    }

    @discardableResult
    private func compactIfUseful(file: URL) throws -> Bool {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= 4096, size <= 512 * 1024 * 1024 else { return false }
        let archiveURL = file.deletingLastPathComponent().appendingPathComponent("text-compact-\(UUID().uuidString).tmp")
        guard let archive = Archive(url: archiveURL, accessMode: .create) else { return false }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var index = 0
        while true {
            guard let data = try handle.read(upToCount: Self.blockBytes), !data.isEmpty else { break }
            try add(data: data, path: "text/\(index)", archive: archive); index += 1
        }
        try add(data: Data("\(Self.blockBytes):\(size)".utf8), path: "moread-text-v1", archive: archive)
        let compressedSize = ((try? FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size]) as? NSNumber)?.int64Value ?? Int64.max
        if compressedSize >= size { try? FileManager.default.removeItem(at: archiveURL); return false }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: archiveURL, to: file)
        return true
    }

    private func add(data: Data, path: String, archive: Archive) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: UInt32(data.count), compressionMethod: .deflate) { position, size in
            let start = Int(position); let end = min(data.count, start + size)
            return data.subdata(in: start..<end)
        }
    }

    private func isZip(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let data = try handle.read(upToCount: 4) ?? Data()
        return data.elementsEqual([0x50, 0x4B, 0x03, 0x04])
    }

    private func touch(_ key: CacheKey) { cacheOrder.removeAll { $0 == key }; cacheOrder.append(key) }
    private func trimCache() { while cacheOrder.count > decodedCacheLimit { cache.removeValue(forKey: cacheOrder.removeFirst()) } }
}

private extension String {
    func trimmingLeadingCharacters(in set: CharacterSet) -> String {
        guard let first = unicodeScalars.firstIndex(where: { !set.contains($0) }) else { return "" }
        return String(unicodeScalars[first...])
    }
}
