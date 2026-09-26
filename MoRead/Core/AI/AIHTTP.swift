import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum AIClientError: LocalizedError {
  case invalidURL
  case http(Int, String)
  case malformed(String)
  case empty
  case unsupported(String)
  var errorDescription: String? {
    switch self {
    case .invalidURL: "AI 服务地址无效"
    case .http(let code, let message): "AI 服务返回 \(code)：\(message)"
    case .malformed(let message): "AI 响应格式错误：\(message)"
    case .empty: "AI 返回了空内容"
    case .unsupported(let message): message
    }
  }
}

struct SSEEvent: Sendable {
  var event: String?
  var data: String
}

enum AIHTTP {
  static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    config.timeoutIntervalForResource = 60 * 60
    config.waitsForConnectivity = true
    return URLSession(configuration: config)
  }()

  static func request(
    url: URL, headers: [String: String], json: [String: Any], method: String = "POST"
  ) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    request.httpBody = try JSONSerialization.data(withJSONObject: json)
    return request
  }

  static func data(for request: URLRequest) async throws -> Data {
    let started = Date()
    do {
      let (data, response) = try await session.data(for: request)
      let http = response as? HTTPURLResponse
      await APICallLogger.record(request: request, startedAt: started, response: http, responseBytes: data.count, category: "AI")
      guard let http else { throw AIClientError.malformed("缺少 HTTP 响应") }
      guard 200..<300 ~= http.statusCode else {
        let text = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        throw AIClientError.http(http.statusCode, extractError(text))
      }
      return data
    } catch {
      await APICallLogger.record(request: request, startedAt: started, response: nil, responseBytes: 0, category: "AI", error: error)
      throw error
    }
  }

  static func sse(for request: URLRequest) -> AsyncThrowingStream<SSEEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        let started = Date()
        do {
          let (bytes, response) = try await session.bytes(for: request)
          guard let http = response as? HTTPURLResponse else {
            await APICallLogger.record(request: request, startedAt: started, response: nil, responseBytes: 0, category: "AI-Stream")
            throw AIClientError.malformed("缺少 HTTP 响应")
          }
          await APICallLogger.record(request: request, startedAt: started, response: http, responseBytes: 0, category: "AI-Stream")
          guard 200..<300 ~= http.statusCode else {
            var body = ""
            for try await line in bytes.lines {
              body += line + "\n"
              if body.count > 64_000 { break }
            }
            throw AIClientError.http(http.statusCode, extractError(body))
          }
          var event: String?
          var dataLines: [String] = []
          for try await line in bytes.lines {
            if Task.isCancelled { break }
            if line.isEmpty {
              if !dataLines.isEmpty {
                continuation.yield(.init(event: event, data: dataLines.joined(separator: "\n")))
              }
              event = nil
              dataLines.removeAll(keepingCapacity: true)
              continue
            }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
              event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
              dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
          }
          if !dataLines.isEmpty {
            continuation.yield(.init(event: event, data: dataLines.joined(separator: "\n")))
          }
          continuation.finish()
        } catch is CancellationError { continuation.finish() } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  static func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AIClientError.malformed("顶层不是 JSON 对象")
    }
    return value
  }
  static func jsonObject(_ string: String) -> [String: Any]? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
  static func merge(_ base: [String: Any], extras: [String: Any]?) -> [String: Any] {
    var out = base
    extras?.forEach { out[$0] = $1 }
    return out
  }
  static func normalizedBase(_ raw: String, stripping suffixes: [String] = []) -> String {
    var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    for suffix in suffixes where base.hasSuffix(suffix) {
      base.removeLast(suffix.count)
      while base.hasSuffix("/") { base.removeLast() }
      break
    }
    return base
  }
  static func endpoint(base: String, path: String) throws -> URL {
    let value = base + (path.hasPrefix("/") ? path : "/" + path)
    guard let url = URL(string: value) else { throw AIClientError.invalidURL }
    return url
  }
  static func extractError(_ body: String) -> String {
    if let obj = jsonObject(body), let error = obj["error"] as? [String: Any],
      let message = error["message"] as? String
    {
      return message
    }
    return String(body.prefix(1000))
  }
}

struct RequestOverrides: @unchecked Sendable {
  var headers: [String: String] = [:]
  var body: [String: Any] = [:]
  static func parse(_ raw: String?) -> RequestOverrides {
    guard let raw, let data = raw.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .init() }
    return .init(
      headers: root["headers"] as? [String: String] ?? [:],
      body: root["body"] as? [String: Any] ?? [:])
  }
  static func merge(provider: String?, model: String?) -> String {
    func object(_ raw: String?) -> [String: Any] {
      guard let raw, let data = raw.data(using: .utf8) else { return [:] }
      return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    let p = object(provider)
    let m = object(model)
    var out = p
    for (k, v) in m { out[k] = v }
    for key in ["headers", "body"] {
      var nested = p[key] as? [String: Any] ?? [:]
      (m[key] as? [String: Any] ?? [:]).forEach { nested[$0] = $1 }
      if !nested.isEmpty { out[key] = nested }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
      let s = String(data: data, encoding: .utf8)
    else { return "{}" }
    return s
  }
}

private let optionalResponsesTuning: Set<String> = [
  "temperature", "top_p", "top_logprobs", "logprobs", "presence_penalty", "frequency_penalty",
  "seed", "reasoning.effort", "reasoning.summary", "text.verbosity", "verbosity",
]

func removingRejectedResponsesParameter(payload: [String: Any], errorBody: String) -> [String: Any]?
{
  guard let root = AIHTTP.jsonObject(errorBody), let error = root["error"] as? [String: Any] else {
    return nil
  }
  let message = (error["message"] as? String) ?? ""
  let code = (error["code"] as? String) ?? ""
  let unsupported =
    ["unsupported_parameter", "unknown_parameter", "unsupported_value"].contains(code)
    || message.range(
      of:
        "unsupported|unknown parameter|unrecognized (request )?(argument|parameter)|not supported|does not support",
      options: .regularExpression) != nil
  guard unsupported else { return nil }
  var parameter = (error["param"] as? String) ?? ""
  if parameter.isEmpty,
    let regex = try? NSRegularExpression(
      pattern: #"(?:parameter|argument|value)\s*:?\s*['\"`]([a-z_][a-z_0-9.]*)['\"`]"#,
      options: .caseInsensitive)
  {
    let ns = message as NSString
    if let match = regex.firstMatch(in: message, range: NSRange(location: 0, length: ns.length)),
      match.numberOfRanges > 1
    {
      parameter = ns.substring(with: match.range(at: 1))
    }
  }
  guard optionalResponsesTuning.contains(parameter) else { return nil }
  func remove(_ object: [String: Any], path: ArraySlice<String>) -> [String: Any]? {
    guard let key = path.first, object[key] != nil else { return nil }
    var out = object
    if path.count == 1 {
      out.removeValue(forKey: key)
    } else {
      guard let child = object[key] as? [String: Any],
        let adjusted = remove(child, path: path.dropFirst())
      else { return nil }
      if adjusted.isEmpty { out.removeValue(forKey: key) } else { out[key] = adjusted }
    }
    return out
  }
  return remove(payload, path: parameter.split(separator: ".").map(String.init)[...])
}
