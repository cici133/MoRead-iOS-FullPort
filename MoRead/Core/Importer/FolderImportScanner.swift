import Foundation

struct FolderBookCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let sizeBytes: Int64
    let relativeDirectory: String
    let looksImported: Bool
}

struct FolderImportSession: Identifiable, Sendable {
    let id: String
    let rootName: String
    let stagingRoot: URL
    let candidates: [FolderBookCandidate]

    func cleanup() {
        try? FileManager.default.removeItem(at: stagingRoot)
    }
}

enum FolderImportScanner {
    static let maxFiles = 500
    static let maxDepth = 8
    static let supportedExtensions: Set<String> = ["txt", "epub"]
    private static let skippedDirectories: Set<String> = [
        "android", "cache", "caches", "temp", "tmp", "log", "logs", "thumbnails"
    ]

    static func prepare(folderURL: URL, existingTitles: Set<String>) async throws -> FolderImportSession {
        try await Task.detached(priority: .userInitiated) {
            let access = folderURL.startAccessingSecurityScopedResource()
            defer { if access { folderURL.stopAccessingSecurityScopedResource() } }

            let fm = FileManager.default
            let sessionId = UUID().uuidString
            let root = try MoReadDatabase.applicationDirectory()
                .appendingPathComponent("folder-import-staging", isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            var candidates: [FolderBookCandidate] = []
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .nameKey]
            guard let enumerator = fm.enumerator(
                at: folderURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                return FolderImportSession(id: sessionId, rootName: folderURL.lastPathComponent, stagingRoot: root, candidates: [])
            }

            let baseComponents = folderURL.standardizedFileURL.pathComponents.count
            for case let item as URL in enumerator {
                try Task.checkCancellation()
                if candidates.count >= maxFiles { break }
                let relativeComponents = Array(item.standardizedFileURL.pathComponents.dropFirst(baseComponents))
                let depth = max(0, relativeComponents.count - 1)
                if depth > maxDepth {
                    if (try? item.resourceValues(forKeys: keys).isDirectory) == true { enumerator.skipDescendants() }
                    continue
                }
                let values = try? item.resourceValues(forKeys: keys)
                if values?.isDirectory == true {
                    if isSkippableDirectory(item.lastPathComponent) { enumerator.skipDescendants() }
                    continue
                }
                guard isSupportedBook(item.lastPathComponent) else { continue }

                let relativeDirectory = relativeComponents.dropLast().joined(separator: "/")
                let targetDir = relativeDirectory.isEmpty ? root : root.appendingPathComponent(relativeDirectory, isDirectory: true)
                try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
                var target = targetDir.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    target = targetDir.appendingPathComponent("\(UUID().uuidString)-\(item.lastPathComponent)")
                }
                try fm.copyItem(at: item, to: target)
                let titleKey = item.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                candidates.append(.init(
                    id: relativeComponents.joined(separator: "/"),
                    url: target,
                    name: item.lastPathComponent,
                    sizeBytes: Int64(values?.fileSize ?? 0),
                    relativeDirectory: relativeDirectory,
                    looksImported: existingTitles.contains(titleKey)
                ))
            }

            candidates.sort {
                if $0.relativeDirectory != $1.relativeDirectory { return $0.relativeDirectory.localizedStandardCompare($1.relativeDirectory) == .orderedAscending }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return FolderImportSession(id: sessionId, rootName: folderURL.lastPathComponent, stagingRoot: root, candidates: candidates)
        }.value
    }

    static func isSupportedBook(_ name: String) -> Bool {
        supportedExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    static func isSkippableDirectory(_ name: String) -> Bool {
        name.hasPrefix(".") || skippedDirectories.contains(name.lowercased())
    }
}
