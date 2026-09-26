import Foundation

enum ApiDialect: String, Codable, CaseIterable, Sendable {
  case openAI = "OPENAI"
  case openAIResponses = "OPENAI_RESPONSES"
  case claude = "CLAUDE"
  case gemini = "GEMINI"
}
enum AiProviderAdapter: String, Codable, CaseIterable, Sendable {
  case custom = "CUSTOM"
  case openRouter = "OPENROUTER"
  case openAI = "OPENAI"
  case anthropic = "ANTHROPIC"
  case gemini = "GEMINI"
  case deepSeek = "DEEPSEEK"
  case miniMax = "MINIMAX"
}
enum AiModelType: String, Codable, CaseIterable, Sendable {
  case chat = "CHAT"
  case embedding = "EMBEDDING"
  case rerank = "RERANK"
  case tts = "TTS"
  case image = "IMAGE"
}
enum ModelRole: String, Codable, CaseIterable, Sendable {
  case chat = "CHAT"
  case translation = "TRANSLATION"
  case cheap = "CHEAP"
  case suggestion = "SUGGESTION"
  case proactiveAnnotation = "PROACTIVE_ANNOTATION"
  case embedding = "EMBEDDING"
  case rerank = "RERANK"
  case tts = "TTS"
  case image = "IMAGE"
}
enum ChatRole: String, Codable, Sendable { case system, user, assistant, tool }

enum ReasoningEffort: String, Codable, Sendable {
  case low, medium, high
  var budgetTokens: Int {
    switch self {
    case .low: 2048
    case .medium: 8192
    case .high: 16384
    }
  }
}
enum PromptCacheTTL: String, Codable, Sendable {
  case fiveMinutes = "5m"
  case oneHour = "1h"
}

struct ToolCall: Codable, Hashable, Sendable {
  var id: String
  var name: String
  var arguments: String
  var thoughtSignature: String?
  var extraContent: [String: JSONValue]?
  var reasoningDetails: [[String: JSONValue]] = []
}

struct ToolSpec: @unchecked Sendable {
  var name: String
  var description: String
  var parameters: [String: Any]
}

enum ChatPart: Sendable {
  case text(String)
  case image(base64: String, mimeType: String)
}

struct AIChatMessage: Sendable {
  var role: ChatRole
  var content: String
  var toolCalls: [ToolCall] = []
  var toolCallId: String? = nil
  var parts: [ChatPart] = []
}

enum ChatDelta: Sendable {
  case usage(inputTokens: Int64?, outputTokens: Int64?, totalTokens: Int64?)
  case text(String)
  case reasoning(String)
  case toolCalls([ToolCall])
}

struct ChatOptions: @unchecked Sendable {
  var temperature: Double? = nil
  var topP: Double? = nil
  var maxTokens: Int? = nil
  var reasoning: ReasoningEffort? = nil
  var cacheTTL: PromptCacheTTL? = .fiveMinutes
  var extraHeaders: [String: String] = [:]
  var extraBody: [String: Any]? = nil

  static let `default` = ChatOptions()

  static func fromExtraJSON(_ raw: String?) -> ChatOptions {
    guard let raw, let data = raw.data(using: .utf8),
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return .default }
    var value = ChatOptions()
    value.temperature = (root["temperature"] as? NSNumber)?.doubleValue
    value.topP = (root["top_p"] as? NSNumber)?.doubleValue
    value.maxTokens = (root["max_tokens"] as? NSNumber)?.intValue
    if let r = root["reasoning"] as? String {
      value.reasoning = ReasoningEffort(rawValue: r.lowercased())
    }
    let cache = (root["cache_prompt"] as? Bool) ?? true
    value.cacheTTL =
      cache ? PromptCacheTTL(rawValue: (root["cache_ttl"] as? String) ?? "5m") ?? .fiveMinutes : nil
    value.extraHeaders = root["headers"] as? [String: String] ?? [:]
    value.extraBody = root["body"] as? [String: Any]
    return value
  }
}

struct AIProviderRecord: Identifiable, Hashable, Sendable {
  var id: Int64
  var name: String
  var baseURL: String
  var apiKeyAlias: String
  var type: String
  var extraJSON: String
  var apiFormat: ApiDialect
  var adapter: AiProviderAdapter
  var createdAt: Int64
}

struct AIModelRecord: Identifiable, Hashable, Sendable {
  var id: Int64
  var providerId: Int64
  var modelName: String
  var type: AiModelType
  var chatApiFormat: String
  var endpointPath: String
  var extraJSON: String
  var createdAt: Int64
}

/// Codable JSON tree used only where tool metadata must survive persistence without losing fields.
enum JSONValue: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([JSONValue].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
}

enum ModelProtocolRoute: Sendable {
  case chat(ApiDialect)
  case embedding(ApiDialect)
  case rerank, media
  case unsupported(String)
}

enum ProviderProtocolPolicy {
  static func supportedChatDialects(_ adapter: AiProviderAdapter) -> [ApiDialect] {
    switch adapter {
    case .openRouter: return [.openAI, .openAIResponses, .claude]
    case .openAI: return [.openAI, .openAIResponses]
    case .anthropic: return [.claude]
    case .gemini: return [.gemini]
    case .deepSeek, .miniMax: return [.openAI]
    case .custom: return ApiDialect.allCases
    }
  }
  static func defaultChatDialect(_ adapter: AiProviderAdapter) -> ApiDialect {
    switch adapter {
    case .anthropic: .claude
    case .gemini: .gemini
    default: .openAI
    }
  }
  static func normalize(adapter: AiProviderAdapter, requested: ApiDialect) -> ApiDialect {
    supportedChatDialects(adapter).contains(requested) ? requested : defaultChatDialect(adapter)
  }
  static func modelDialect(provider: AIProviderRecord, model: AIModelRecord) -> ApiDialect {
    let requested = ApiDialect(rawValue: model.chatApiFormat).map { $0 } ?? provider.apiFormat
    return normalize(adapter: provider.adapter, requested: requested)
  }
  static func route(provider: AIProviderRecord, model: AIModelRecord) -> ModelProtocolRoute {
    switch model.type {
    case .chat: return .chat(modelDialect(provider: provider, model: model))
    case .embedding:
      switch provider.adapter {
      case .openRouter, .openAI: return .embedding(.openAI)
      case .gemini: return .embedding(.gemini)
      case .custom:
        return provider.apiFormat == .gemini
          ? .embedding(.gemini)
          : provider.apiFormat == .claude
            ? .unsupported("Anthropic Messages 不提供 embedding") : .embedding(.openAI)
      default: return .unsupported("该供应商内置适配不提供 embedding")
      }
    case .rerank:
      return provider.adapter == .custom ? .rerank : .unsupported("重排模型请使用支持 /rerank 的自定义供应商")
    case .tts:
      if provider.adapter == .gemini
        || (provider.adapter == .custom && provider.apiFormat == .gemini)
      {
        return .media
      }
      fallthrough
    case .image:
      switch provider.adapter {
      case .openRouter, .openAI, .miniMax: return .media
      case .custom where provider.apiFormat == .openAI || provider.apiFormat == .openAIResponses:
        return .media
      default: return .unsupported("当前供应商协议不支持该媒体能力")
      }
    }
  }
}
