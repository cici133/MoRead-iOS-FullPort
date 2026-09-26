import Foundation

private final class WebDAVTransferDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias Progress = @Sendable (_ completed: Int64, _ total: Int64) -> Void
    let progress: Progress
    let downloadTarget: URL?
    var continuation: CheckedContinuation<URLResponse, Error>?
    var moveError: Error?

    init(downloadTarget: URL? = nil, progress: @escaping Progress) {
        self.downloadTarget = downloadTarget
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let target = downloadTarget else { return }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: target)
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error); return }
        if let moveError { continuation.resume(throwing: moveError); return }
        if let response = task.response { continuation.resume(returning: response) }
        else { continuation.resume(throwing: URLError(.badServerResponse)) }
    }
}

actor WebDAVClient {
    static let shared = WebDAVClient()
    static let backupExtension = ".moread.zip"
    typealias TransferProgress = @Sendable (_ completed: Int64, _ total: Int64) -> Void

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }()

    func test(_ credentials: WebDAVCredentials) async throws {
        let root = try baseURL(credentials)
        _ = try await request(credentials, url: root, method: "PROPFIND", headers: ["Depth":"0"], body: Self.propfind)
        _ = try await ensureDirectory(credentials)
    }

    func list(_ credentials: WebDAVCredentials, suffixes: Set<String> = [backupExtension]) async throws -> [RemoteBackup] {
        let dir = try await ensureDirectory(credentials)
        let (data, _) = try await request(credentials, url: dir, method: "PROPFIND", headers: ["Depth":"1"], body: Self.propfind)
        return WebDAVXML.parse(data)
            .filter { item in suffixes.contains { item.name.lowercased().hasSuffix($0.lowercased()) } }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func upload(_ credentials: WebDAVCredentials, file: URL, remoteName: String,
                onProgress: @escaping TransferProgress = { _, _ in }) async throws {
        let dir = try await ensureDirectory(credentials)
        let target = dir.appendingPathComponent(remoteName, isDirectory: false)
        var request = URLRequest(url: target)
        request.httpMethod = "PUT"
        request.setValue(basic(credentials), forHTTPHeaderField: "Authorization")
        request.setValue("MoRead-WebDAV", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let response = try await transfer(request: request, uploadFile: file, downloadTo: nil, onProgress: onProgress)
        try validate(response)
    }

    func download(_ credentials: WebDAVCredentials, remoteName: String, to output: URL,
                  onProgress: @escaping TransferProgress = { _, _ in }) async throws {
        let dir = try await ensureDirectory(credentials)
        let target = dir.appendingPathComponent(remoteName)
        var request = URLRequest(url: target)
        request.setValue(basic(credentials), forHTTPHeaderField: "Authorization")
        request.setValue("MoRead-WebDAV", forHTTPHeaderField: "User-Agent")
        let response = try await transfer(request: request, uploadFile: nil, downloadTo: output, onProgress: onProgress)
        try validate(response)
    }

    func delete(_ credentials: WebDAVCredentials, remoteName: String) async throws {
        let dir = try await ensureDirectory(credentials)
        _ = try await request(credentials, url: dir.appendingPathComponent(remoteName), method: "DELETE")
    }

    private func transfer(request: URLRequest, uploadFile: URL?, downloadTo: URL?,
                          onProgress: @escaping TransferProgress) async throws -> URLResponse {
        let delegate = WebDAVTransferDelegate(downloadTarget: downloadTo, progress: onProgress)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let transferSession = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        defer { transferSession.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let task: URLSessionTask = uploadFile.map { transferSession.uploadTask(with: request, fromFile: $0) }
                ?? transferSession.downloadTask(with: request)
            task.resume()
        }
    }

    private func ensureDirectory(_ credentials: WebDAVCredentials) async throws -> URL {
        var current = try baseURL(credentials)
        for segment in credentials.remoteDirectory.split(separator: "/").map(String.init).filter({ !$0.isEmpty }) {
            current = current.appendingPathComponent(segment, isDirectory: true)
            do {
                _ = try await request(credentials, url: current, method: "PROPFIND", headers: ["Depth":"0"], body: Self.propfind)
            } catch {
                do { _ = try await request(credentials, url: current, method: "MKCOL") }
                catch let e as BackupError {
                    if case .network(let s) = e, s.contains("405") { }
                    else { throw e }
                }
            }
        }
        return current
    }

    private func baseURL(_ credentials: WebDAVCredentials) throws -> URL {
        guard var url = URL(string: credentials.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https" else {
            throw BackupError.invalidConfiguration("为保护账号密码，WebDAV 地址必须使用 HTTPS")
        }
        if !url.absoluteString.hasSuffix("/") { url.appendPathComponent("") }
        return url
    }

    private func request(_ credentials: WebDAVCredentials, url: URL, method: String,
                         headers: [String:String] = [:], body: Data? = nil) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(basic(credentials), forHTTPHeaderField: "Authorization")
        request.setValue("MoRead-WebDAV", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/xml", forHTTPHeaderField: "Content-Type") }
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let pair = try await session.data(for: request)
        try validate(pair.1)
        return pair
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 207 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw BackupError.network("WebDAV 账号或密码错误") }
            throw BackupError.network("WebDAV 返回 \(http.statusCode)")
        }
    }

    private func basic(_ credentials: WebDAVCredentials) -> String {
        "Basic " + Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
    }

    private static let propfind = Data("<?xml version=\"1.0\" encoding=\"utf-8\" ?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:getcontentlength/><d:getlastmodified/><d:resourcetype/></d:prop></d:propfind>".utf8)
}

private final class WebDAVXML: NSObject, XMLParserDelegate {
    private var items: [RemoteBackup] = [], current: [String:String] = [:], field: String?, text = ""
    static func parse(_ data: Data) -> [RemoteBackup] { let d=WebDAVXML(); let p=XMLParser(data:data); p.delegate=d; p.shouldProcessNamespaces=true; _=p.parse(); return d.items }
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName qName:String?,attributes:[String:String]){let n=elementName.lowercased();if n.hasSuffix("response"){current=[:]};if ["href","displayname","getcontentlength","getlastmodified"].contains(where:{n.hasSuffix($0)}){field=n.split(separator:":").last.map(String.init) ?? n;text=""}}
    func parser(_ parser:XMLParser,foundCharacters string:String){if field != nil{text += string}}
    func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName qName:String?){let n=elementName.lowercased();if let f=field,n.hasSuffix(f){current[f]=text.trimmingCharacters(in:.whitespacesAndNewlines);field=nil};if n.hasSuffix("response"){let href=current["href"] ?? "",display=current["displayname"]?.nonEmpty;let raw=display ?? href.trimmingCharacters(in:CharacterSet(charactersIn:"/")).split(separator:"/").last.map(String.init) ?? "";let name=raw.removingPercentEncoding ?? raw;if !name.isEmpty{let size=Int64(current["getcontentlength"] ?? "") ?? 0;let mod=Self.date(current["getlastmodified"]);items.append(.init(name:name,size:size,modifiedAt:mod))}}}
    private static func date(_ value:String?)->Int64{guard let value else{return 0};let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.dateFormat="EEE, dd MMM yyyy HH:mm:ss zzz";return Int64((f.date(from:value)?.timeIntervalSince1970 ?? 0)*1000)}
}
private extension String{var nonEmpty:String?{let t=trimmingCharacters(in:.whitespacesAndNewlines);return t.isEmpty ? nil:t}}
