import Foundation

final class ClaudeClient: AIProtocolClient, @unchecked Sendable {
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let endpointPath: String
    private let overrides: RequestOverrides

    init(baseURL: String, apiKey: String, model: String, endpointPath: String = "", extraJSON: String = "{}") {
        self.baseURL = AIHTTP.normalizedBase(baseURL, stripping: ["/v1"])
        self.apiKey = apiKey
        self.model = model
        self.endpointPath = endpointPath
        self.overrides = .parse(extraJSON)
    }

    func chatStream(messages: [AIChatMessage], tools: [ToolSpec] = [], options: ChatOptions = .default) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildRequest(messages: messages, tools: tools, options: options, stream: true)
                    var toolSlots: [Int: (id: String, name: String, json: String)] = [:]
                    for try await event in AIHTTP.sse(for: request) {
                        guard let root = AIHTTP.jsonObject(event.data) else { continue }
                        let type = event.event ?? (root["type"] as? String)
                        switch type {
                        case "message_start":
                            if let message = root["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] {
                                continuation.yield(.usage(inputTokens: aiInt64(usage["input_tokens"]), outputTokens: aiInt64(usage["output_tokens"]), totalTokens: nil))
                            }
                        case "content_block_start":
                            guard let index = (root["index"] as? NSNumber)?.intValue,
                                  let block = root["content_block"] as? [String: Any] else { continue }
                            if block["type"] as? String == "tool_use" {
                                let id = (block["id"] as? String) ?? UUID().uuidString
                                let name = (block["name"] as? String) ?? ""
                                let input = block["input"] ?? [:]
                                let data = try? JSONSerialization.data(withJSONObject: input)
                                toolSlots[index] = (id, name, data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
                            }
                        case "content_block_delta":
                            guard let delta = root["delta"] as? [String: Any] else { continue }
                            switch delta["type"] as? String {
                            case "text_delta": if let text = delta["text"] as? String { continuation.yield(.text(text)) }
                            case "thinking_delta": if let text = delta["thinking"] as? String { continuation.yield(.reasoning(text)) }
                            case "input_json_delta":
                                if let index = (root["index"] as? NSNumber)?.intValue, var slot = toolSlots[index], let partial = delta["partial_json"] as? String {
                                    if slot.json == "{}" { slot.json = "" }
                                    slot.json += partial; toolSlots[index] = slot
                                }
                            default: break
                            }
                        case "message_delta":
                            if let usage = root["usage"] as? [String: Any] {
                                continuation.yield(.usage(inputTokens: aiInt64(usage["input_tokens"]), outputTokens: aiInt64(usage["output_tokens"]), totalTokens: nil))
                            }
                        case "error":
                            let error = root["error"] as? [String: Any]
                            throw AIClientError.http(200, (error?["message"] as? String) ?? "Anthropic stream error")
                        case "message_stop": break
                        default: break
                        }
                    }
                    if !toolSlots.isEmpty {
                        continuation.yield(.toolCalls(toolSlots.keys.sorted().map { key in
                            let slot = toolSlots[key]!; return ToolCall(id: slot.id, name: slot.name, arguments: slot.json.isEmpty ? "{}" : slot.json)
                        }))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func chat(messages: [AIChatMessage], options: ChatOptions = .default) async throws -> String {
        let request = try buildRequest(messages: messages, tools: [], options: options, stream: false)
        let root = try AIHTTP.jsonObject(try await AIHTTP.data(for: request))
        let content = root["content"] as? [[String: Any]] ?? []
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIClientError.empty }
        return text
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        throw AIClientError.unsupported("Claude 接口不提供 embedding，请为 Embedding 角色分配 OpenAI 兼容或 Gemini Provider")
    }

    private func buildRequest(messages: [AIChatMessage], tools: [ToolSpec], options: ChatOptions, stream: Bool) throws -> URLRequest {
        let url = try AIHTTP.endpoint(base: baseURL, path: endpointPath.isEmpty ? "/v1/messages" : endpointPath)
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let thinking = options.reasoning
        let maxTokens = thinking.map { max(options.maxTokens ?? 4096, $0.budgetTokens + 2048) } ?? options.maxTokens ?? 4096
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": stream,
            "messages": encodeTurns(messages)
        ]
        if !system.isEmpty {
            var block: [String: Any] = ["type": "text", "text": system]
            if let ttl = options.cacheTTL {
                var cache: [String: Any] = ["type": "ephemeral"]
                if ttl == .oneHour { cache["ttl"] = ttl.rawValue }
                block["cache_control"] = cache
            }
            body["system"] = [block]
        }
        if !tools.isEmpty {
            body["tools"] = tools.enumerated().map { index, tool -> [String: Any] in
                var value: [String: Any] = ["name": tool.name, "description": tool.description, "input_schema": tool.parameters]
                if index == tools.count - 1, let ttl = options.cacheTTL {
                    var cache: [String: Any] = ["type": "ephemeral"]
                    if ttl == .oneHour { cache["ttl"] = ttl.rawValue }
                    value["cache_control"] = cache
                }
                return value
            }
        }
        if let thinking {
            body["thinking"] = ["type": "enabled", "budget_tokens": thinking.budgetTokens]
        } else {
            if let value = options.temperature { body["temperature"] = value }
            if let value = options.topP { body["top_p"] = value }
        }
        body = AIHTTP.merge(body, extras: overrides.body)
        body = AIHTTP.merge(body, extras: options.extraBody)
        var headers = overrides.headers
        headers["x-api-key"] = apiKey
        headers["anthropic-version"] = "2023-06-01"
        if options.cacheTTL == .oneHour { headers["anthropic-beta"] = "extended-cache-ttl-2025-04-11" }
        options.extraHeaders.forEach { headers[$0] = $1 }
        return try AIHTTP.request(url: url, headers: headers, json: body)
    }

    private func encodeTurns(_ messages: [AIChatMessage]) -> [[String: Any]] {
        let turns = messages.filter { $0.role != .system }
        var result: [[String: Any]] = []
        var index = 0
        while index < turns.count {
            let message = turns[index]
            if message.role == .tool {
                var blocks: [[String: Any]] = []
                while index < turns.count, turns[index].role == .tool {
                    let item = turns[index]
                    blocks.append(["type": "tool_result", "tool_use_id": item.toolCallId ?? "", "content": item.content])
                    index += 1
                }
                result.append(["role": "user", "content": blocks]); continue
            }
            if message.role == .assistant {
                var blocks: [[String: Any]] = []
                if !message.content.isEmpty { blocks.append(["type": "text", "text": message.content]) }
                for call in message.toolCalls {
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) ?? [:]
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
                }
                result.append(["role": "assistant", "content": blocks]); index += 1; continue
            }
            var blocks: [[String: Any]] = []
            if message.parts.isEmpty { blocks.append(["type": "text", "text": message.content]) }
            else {
                for part in message.parts {
                    switch part {
                    case let .text(text): blocks.append(["type": "text", "text": text])
                    case let .image(base64, mime): blocks.append(["type": "image", "source": ["type": "base64", "media_type": mime, "data": base64]])
                    }
                }
            }
            result.append(["role": "user", "content": blocks]); index += 1
        }
        return result
    }
}

final class GeminiClient: AIProtocolClient, @unchecked Sendable {
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let overrides: RequestOverrides

    init(baseURL: String, apiKey: String, model: String, extraJSON: String = "{}") {
        self.baseURL = AIHTTP.normalizedBase(baseURL, stripping: ["/v1beta", "/v1"])
        self.apiKey = apiKey
        self.model = model
        self.overrides = .parse(extraJSON)
    }

    func chatStream(messages: [AIChatMessage], tools: [ToolSpec] = [], options: ChatOptions = .default) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try AIHTTP.endpoint(base: baseURL, path: "/v1beta/models/\(model):streamGenerateContent?alt=sse")
                    let request = try buildRequest(url: url, messages: messages, tools: tools, options: options)
                    var calls: [ToolCall] = []
                    for try await event in AIHTTP.sse(for: request) {
                        guard let root = AIHTTP.jsonObject(event.data) else { continue }
                        if let usage = root["usageMetadata"] as? [String: Any] {
                            continuation.yield(.usage(inputTokens: aiInt64(usage["promptTokenCount"]), outputTokens: aiInt64(usage["candidatesTokenCount"]), totalTokens: aiInt64(usage["totalTokenCount"])))
                        }
                        let parts = (((root["candidates"] as? [[String: Any]])?.first)?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                        for part in parts {
                            if let text = part["text"] as? String, !text.isEmpty { continuation.yield(part["thought"] as? Bool == true ? .reasoning(text) : .text(text)) }
                            if let fn = part["functionCall"] as? [String: Any], let name = fn["name"] as? String {
                                let args = fn["args"] ?? [:]
                                let data = try JSONSerialization.data(withJSONObject: args)
                                let signature = (part["thoughtSignature"] as? String) ?? (part["thought_signature"] as? String)
                                calls.append(.init(id: "g\(calls.count)_\(name)", name: name, arguments: String(data: data, encoding: .utf8) ?? "{}", thoughtSignature: signature))
                            }
                        }
                    }
                    if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func chat(messages: [AIChatMessage], options: ChatOptions = .default) async throws -> String {
        let url = try AIHTTP.endpoint(base: baseURL, path: "/v1beta/models/\(model):generateContent")
        let root = try AIHTTP.jsonObject(try await AIHTTP.data(for: buildRequest(url: url, messages: messages, tools: [], options: options)))
        let parts = (((root["candidates"] as? [[String: Any]])?.first)?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIClientError.empty }
        return text
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        var result: [[Float]] = []
        for text in texts {
            let url = try AIHTTP.endpoint(base: baseURL, path: "/v1beta/models/\(model):embedContent")
            let request = try AIHTTP.request(url: url, headers: geminiHeaders(), json: ["content": ["parts": [["text": text]]]])
            let root = try AIHTTP.jsonObject(try await AIHTTP.data(for: request))
            guard let values = (root["embedding"] as? [String: Any])?["values"] as? [NSNumber] else { throw AIClientError.malformed("embedContent 无返回向量") }
            result.append(values.map { $0.floatValue })
        }
        return result
    }

    private func buildRequest(url: URL, messages: [AIChatMessage], tools: [ToolSpec], options: ChatOptions) throws -> URLRequest {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var body: [String: Any] = ["contents": encodeContents(messages)]
        if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        if !tools.isEmpty { body["tools"] = [["functionDeclarations": tools.map { ["name": $0.name, "description": $0.description, "parameters": $0.parameters] }]] }
        var config: [String: Any] = [:]
        if let value = options.temperature { config["temperature"] = value }
        if let value = options.topP { config["topP"] = value }
        if let value = options.maxTokens { config["maxOutputTokens"] = value }
        if let value = options.reasoning { config["thinkingConfig"] = ["thinkingBudget": value.budgetTokens] }
        if !config.isEmpty { body["generationConfig"] = config }
        body = AIHTTP.merge(body, extras: overrides.body)
        body = AIHTTP.merge(body, extras: options.extraBody)
        var headers = geminiHeaders(); overrides.headers.forEach { headers[$0] = $1 }; options.extraHeaders.forEach { headers[$0] = $1 }
        return try AIHTTP.request(url: url, headers: headers, json: body)
    }

    private func encodeContents(_ messages: [AIChatMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages where message.role != .system {
            if message.role == .tool {
                let name = message.toolCallId?.split(separator: "_", maxSplits: 1).dropFirst().first.map(String.init) ?? message.toolCallId ?? "tool"
                let response = (try? JSONSerialization.jsonObject(with: Data(message.content.utf8))) ?? ["result": message.content]
                result.append(["role": "user", "parts": [["functionResponse": ["name": name, "response": response]]]])
                continue
            }
            var parts: [[String: Any]] = []
            if message.parts.isEmpty, !message.content.isEmpty { parts.append(["text": message.content]) }
            else {
                for part in message.parts {
                    switch part {
                    case let .text(text): parts.append(["text": text])
                    case let .image(base64, mime): parts.append(["inline_data": ["mime_type": mime, "data": base64]])
                    }
                }
            }
            if message.role == .assistant {
                for call in message.toolCalls {
                    var part: [String: Any] = ["functionCall": ["name": call.name, "args": (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) ?? [:]]]
                    if let signature = call.thoughtSignature { part["thought_signature"] = signature }
                    parts.append(part)
                }
            }
            result.append(["role": message.role == .assistant ? "model" : "user", "parts": parts])
        }
        return result
    }

    private func geminiHeaders() -> [String: String] { ["x-goog-api-key": apiKey] }
}

private func aiInt64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
