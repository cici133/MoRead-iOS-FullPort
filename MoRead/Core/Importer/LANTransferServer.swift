import Darwin
import Foundation
import Network

extension Notification.Name {
    static let moReadLibraryDidChange = Notification.Name("MoReadLibraryDidChange")
}

@MainActor
final class LANTransferServer: ObservableObject {
    static let shared = LANTransferServer()
    @Published private(set) var running = false
    @Published private(set) var address = ""
    @Published private(set) var status = ""
    @Published private(set) var importedCount = 0

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.mozhi.reader.lan-transfer", qos: .userInitiated)
    private let maxRequestBytes = 512 * 1024 * 1024

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.running = true
                        let port = listener?.port?.rawValue ?? 0
                        let host = Self.localIPv4Address() ?? "本机局域网 IP"
                        self.address = "http://\(host):\(port)/"
                        self.status = "等待浏览器上传 TXT / EPUB"
                    case .failed(let error):
                        self.status = error.localizedDescription
                        self.stop()
                    case .cancelled:
                        self.running = false; self.address = ""
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        } catch {
            status = error.localizedDescription
            listener = nil
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        running = false; address = ""; status = "局域网传书已停止"
    }

    private nonisolated func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        var expected: Int?

        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                guard let self else { connection.cancel(); return }
                if let data { buffer.append(data) }
                if buffer.count > self.maxRequestBytes {
                    self.send(connection, status: "413 Payload Too Large", body: "文件过大")
                    return
                }
                if expected == nil, let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                    let length = self.headerValue("Content-Length", in: header).flatMap(Int.init) ?? 0
                    expected = headerEnd.upperBound + length
                }
                if let expected, buffer.count >= expected {
                    let request = Data(buffer.prefix(expected))
                    self.handle(request, connection: connection)
                } else if complete || error != nil {
                    if !buffer.isEmpty { self.handle(buffer, connection: connection) } else { connection.cancel() }
                } else { receiveNext() }
            }
        }
        receiveNext()
    }

    private nonisolated func handle(_ request: Data, connection: NWConnection) {
        guard let headerEnd = request.range(of: Data("\r\n\r\n".utf8)) else {
            send(connection, status: "400 Bad Request", body: "请求格式错误"); return
        }
        let header = String(decoding: request[..<headerEnd.lowerBound], as: UTF8.self)
        let first = header.components(separatedBy: "\r\n").first ?? ""
        if first.hasPrefix("GET ") {
            sendHTML(connection, status: "200 OK", html: Self.uploadPage(message: nil)); return
        }
        guard first.hasPrefix("POST /upload") else {
            send(connection, status: "404 Not Found", body: "Not Found"); return
        }
        guard let contentType = headerValue("Content-Type", in: header),
              let boundary = Self.multipartBoundary(contentType) else {
            send(connection, status: "400 Bad Request", body: "需要 multipart/form-data"); return
        }
        let body = request.subdata(in: headerEnd.upperBound..<request.count)
        guard let upload = Self.firstUploadedFile(body: body, boundary: boundary) else {
            sendHTML(connection, status: "400 Bad Request", html: Self.uploadPage(message: "没有找到上传文件")); return
        }
        let filename = URL(fileURLWithPath: upload.filename).lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard ext == "txt" || ext == "epub" else {
            sendHTML(connection, status: "415 Unsupported Media Type", html: Self.uploadPage(message: "只支持 TXT / EPUB")); return
        }
        Task {
            do {
                let root = try MoReadDatabase.applicationDirectory().appendingPathComponent("lan-inbox", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let file = root.appendingPathComponent("\(UUID().uuidString)-\(filename)")
                try upload.data.write(to: file, options: .atomic)
                defer { try? FileManager.default.removeItem(at: file) }
                let draft = try await BookImportService.importBook(url: file)
                _ = try await LibraryRepository.shared.importBook(draft)
                await MainActor.run {
                    self.importedCount += 1
                    self.status = "已导入：\(draft.title)"
                    NotificationCenter.default.post(name: .moReadLibraryDidChange, object: nil)
                }
                self.sendHTML(connection, status: "200 OK", html: Self.uploadPage(message: "《\(Self.escapeHTML(draft.title))》导入成功"))
            } catch {
                await MainActor.run { self.status = "导入失败：\(error.localizedDescription)" }
                self.sendHTML(connection, status: "500 Internal Server Error", html: Self.uploadPage(message: "导入失败：\(Self.escapeHTML(error.localizedDescription))"))
            }
        }
    }

    private nonisolated func send(_ connection: NWConnection, status: String, body: String) {
        let data = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private nonisolated func sendHTML(_ connection: NWConnection, status: String, html: String) {
        let data = Data(html.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private nonisolated func headerValue(_ name: String, in header: String) -> String? {
        header.components(separatedBy: "\r\n").dropFirst().first { line in
            line.lowercased().hasPrefix(name.lowercased() + ":")
        }?.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private struct Upload { let filename: String; let data: Data }

    private nonisolated static func multipartBoundary(_ contentType: String) -> String? {
        contentType.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.lowercased().hasPrefix("boundary=") }?
            .dropFirst("boundary=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private nonisolated static func firstUploadedFile(body: Data, boundary: String) -> Upload? {
        let marker = Data("--\(boundary)".utf8)
        var cursor = body.startIndex
        while let boundaryRange = body.range(of: marker, options: [], in: cursor..<body.endIndex) {
            var partStart = boundaryRange.upperBound
            if body.count >= partStart + 2, body[partStart] == 13, body[partStart + 1] == 10 { partStart += 2 }
            guard let next = body.range(of: marker, options: [], in: partStart..<body.endIndex) else { break }
            var partEnd = next.lowerBound
            if partEnd >= 2, body[partEnd - 2] == 13, body[partEnd - 1] == 10 { partEnd -= 2 }
            if partStart < partEnd {
                let part = body.subdata(in: partStart..<partEnd)
                if let split = part.range(of: Data("\r\n\r\n".utf8)) {
                    let headers = String(decoding: part[..<split.lowerBound], as: UTF8.self)
                    if let match = headers.range(of: #"filename="[^"]*""#, options: .regularExpression) {
                        let raw = String(headers[match]).dropFirst("filename=\"".count).dropLast()
                        let data = part.subdata(in: split.upperBound..<part.endIndex)
                        if !raw.isEmpty, !data.isEmpty { return Upload(filename: String(raw), data: data) }
                    }
                }
            }
            cursor = next.upperBound
        }
        return nil
    }

    private nonisolated static func uploadPage(message: String?) -> String {
        let notice = message.map { "<p class=msg>\($0)</p>" } ?? ""
        return """
        <!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><meta charset=utf-8>
        <title>墨知局域网传书</title><style>body{font-family:-apple-system,system-ui;max-width:680px;margin:48px auto;padding:0 20px;color:#222}main{padding:28px;border:1px solid #ddd;border-radius:18px}input{display:block;margin:24px 0;width:100%}button{font-size:17px;padding:11px 20px}.msg{padding:12px;background:#eef7ee;border-radius:10px}</style>
        <main><h1>墨知 MoRead</h1><p>选择 TXT 或 EPUB。上传完成后会直接进入书架。</p>\(notice)
        <form method=post action=/upload enctype=multipart/form-data><input type=file name=book accept=".txt,.epub,text/plain,application/epub+zip" required><button type=submit>上传并导入</button></form></main>
        """
    }

    private nonisolated static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func localIPv4Address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidate: String?
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var addr = address.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(&addr, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let ip = String(cString: buffer)
            if name == "en0" { return ip }
            candidate = candidate ?? ip
        }
        return candidate
    }
}
