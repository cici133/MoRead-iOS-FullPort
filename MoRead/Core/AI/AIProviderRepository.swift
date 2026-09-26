import Foundation

struct AIProviderDraft: Sendable {
  var id: Int64 = 0
  var name: String
  var baseURL: String
  var type: String = "CHAT"
  var apiFormat: ApiDialect = .openAI
  var adapter: AiProviderAdapter = .custom
  var extraJSON: String = "{}"
  var apiKey: String = ""
}

struct AIModelDraft: Sendable {
  var id: Int64 = 0
  var modelName: String
  var type: AiModelType = .chat
  var chatApiFormat: String = ""
  var endpointPath: String = ""
  var extraJSON: String = "{}"
}

actor AIProviderRepository {
  static let shared = AIProviderRepository()
  private let database = MoReadDatabase.shared

  func providers() async throws -> [AIProviderRecord] {
    try await database.rows("SELECT * FROM ai_providers ORDER BY createdAt,id").compactMap(
      Self.provider)
  }

  func models(providerId: Int64? = nil) async throws -> [AIModelRecord] {
    let rows =
      if let providerId {
        try await database.rows(
          "SELECT * FROM ai_models WHERE providerId=? ORDER BY createdAt,id", [.integer(providerId)]
        )
      } else {
        try await database.rows("SELECT * FROM ai_models ORDER BY createdAt,id")
      }
    return rows.compactMap(Self.model)
  }

  func provider(id: Int64) async throws -> AIProviderRecord? {
    try await database.rows("SELECT * FROM ai_providers WHERE id=? LIMIT 1", [.integer(id)]).first
      .flatMap(Self.provider)
  }

  func model(id: Int64) async throws -> AIModelRecord? {
    try await database.rows("SELECT * FROM ai_models WHERE id=? LIMIT 1", [.integer(id)]).first
      .flatMap(Self.model)
  }

  func save(_ draft: AIProviderDraft) async throws -> Int64 {
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw ValidationError("Provider 名称不能为空") }
    let baseURL = try normalizeProviderBaseURL(draft.baseURL)
    let existing = draft.id == 0 ? nil : try await provider(id: draft.id)
    let alias = existing?.apiKeyAlias ?? "provider-\(UUID().uuidString)"
    if !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      KeychainStore.set(
        draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: alias)
    }
    let dialect = ProviderProtocolPolicy.normalize(
      adapter: draft.adapter, requested: draft.apiFormat)
    if let existing {
      try await database.execute(
        "UPDATE ai_providers SET name=?,baseUrl=?,type=?,extraJson=?,apiFormat=?,adapter=? WHERE id=?",
        [
          .text(name), .text(baseURL), .text(draft.type),
          .text(draft.extraJSON.isEmpty ? "{}" : draft.extraJSON), .text(dialect.rawValue),
          .text(draft.adapter.rawValue), .integer(existing.id),
        ])
      return existing.id
    }
    return try await database.execute(
      "INSERT INTO ai_providers(name,baseUrl,apiKeyAlias,type,extraJson,apiFormat,adapter,createdAt) VALUES(?,?,?,?,?,?,?,?)",
      [
        .text(name), .text(baseURL), .text(alias), .text(draft.type),
        .text(draft.extraJSON.isEmpty ? "{}" : draft.extraJSON), .text(dialect.rawValue),
        .text(draft.adapter.rawValue), .integer(nowMillis()),
      ])
  }

  func delete(provider: AIProviderRecord) async throws {
    try await database.transaction { db in
      try db.execute(
        "UPDATE model_assignments SET modelId=NULL WHERE modelId IN (SELECT id FROM ai_models WHERE providerId=?)",
        [.integer(provider.id)])
      try db.execute("DELETE FROM ai_providers WHERE id=?", [.integer(provider.id)])
    }
    KeychainStore.delete(account: provider.apiKeyAlias)
  }

  func saveModel(providerId: Int64, draft: AIModelDraft) async throws -> Int64 {
    let name = draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw ValidationError("模型名称不能为空") }
    guard let provider = try await provider(id: providerId) else {
      throw ValidationError("Provider 不存在")
    }
    let endpoint = normalizeEndpointPath(draft.endpointPath)
    let format: String
    if draft.type == .chat, !draft.chatApiFormat.isEmpty {
      let requested = ApiDialect(rawValue: draft.chatApiFormat) ?? .openAI
      format =
        ProviderProtocolPolicy.normalize(adapter: provider.adapter, requested: requested).rawValue
    } else {
      format = ""
    }
    let duplicate = try await database.scalarInt(
      "SELECT id FROM ai_models WHERE providerId=? AND modelName=? AND type=? LIMIT 1",
      [.integer(providerId), .text(name), .text(draft.type.rawValue)])
    if let duplicate, duplicate != draft.id { throw ValidationError("同类型下已存在这个模型") }
    if draft.id != 0 {
      guard let old = try await model(id: draft.id), old.providerId == providerId else {
        throw ValidationError("模型不属于当前 Provider")
      }
      try await database.execute(
        "UPDATE ai_models SET modelName=?,type=?,chatApiFormat=?,endpointPath=?,extraJson=? WHERE id=?",
        [
          .text(name), .text(draft.type.rawValue), .text(format), .text(endpoint),
          .text(draft.extraJSON.isEmpty ? "{}" : draft.extraJSON), .integer(draft.id),
        ])
      return draft.id
    }
    return try await database.execute(
      "INSERT INTO ai_models(providerId,modelName,type,chatApiFormat,endpointPath,extraJson,createdAt) VALUES(?,?,?,?,?,?,?)",
      [
        .integer(providerId), .text(name), .text(draft.type.rawValue), .text(format),
        .text(endpoint), .text(draft.extraJSON.isEmpty ? "{}" : draft.extraJSON),
        .integer(nowMillis()),
      ])
  }

  func removeModel(_ modelId: Int64) async throws {
    try await database.transaction { db in
      try db.execute(
        "UPDATE model_assignments SET modelId=NULL WHERE modelId=?", [.integer(modelId)])
      try db.execute("DELETE FROM ai_models WHERE id=?", [.integer(modelId)])
    }
  }

  func assign(role: ModelRole, modelId: Int64?) async throws {
    if let modelId {
      guard let model = try await model(id: modelId) else { throw ValidationError("模型不存在") }
      guard model.type == requiredType(role) else { throw ValidationError("模型能力与分配角色不匹配") }
      guard let provider = try await provider(id: model.providerId) else {
        throw ValidationError("Provider 不存在")
      }
      if case .unsupported(let reason) = ProviderProtocolPolicy.route(
        provider: provider, model: model)
      {
        throw ValidationError(reason)
      }
    }
    try await database.execute(
      "INSERT INTO model_assignments(role,modelId) VALUES(?,?) ON CONFLICT(role) DO UPDATE SET modelId=excluded.modelId",
      [.text(role.rawValue), modelId.map(SQLValue.integer) ?? .null])
  }

  func assignment(_ role: ModelRole) async throws -> Int64? {
    try await database.rows(
      "SELECT modelId FROM model_assignments WHERE role=?", [.text(role.rawValue)]
    ).first?["modelId"]?.int64
  }

  func apiKey(for provider: AIProviderRecord) -> String {
    KeychainStore.get(account: provider.apiKeyAlias)
  }

  func resolve(_ role: ModelRole) async throws -> (AIProviderRecord, AIModelRecord) {
    var modelId = try await assignment(role)
    if modelId == nil, role == .proactiveAnnotation || role == .suggestion {
      if let cheap = try await assignment(.cheap) { modelId = cheap }
      else { modelId = try await assignment(.chat) }
    }
    if modelId == nil, role == .translation { modelId = try await assignment(.chat) }
    guard let id = modelId, let model = try await model(id: id), model.type == requiredType(role),
      let provider = try await provider(id: model.providerId)
    else {
      throw AIClientError.unsupported("尚未配置\(roleLabel(role))")
    }
    return (provider, model)
  }

  private func requiredType(_ role: ModelRole) -> AiModelType {
    switch role {
    case .chat, .translation, .cheap, .suggestion, .proactiveAnnotation: .chat
    case .embedding: .embedding
    case .rerank: .rerank
    case .tts: .tts
    case .image: .image
    }
  }
  private func roleLabel(_ role: ModelRole) -> String {
    switch role {
    case .chat: "对话模型"
    case .translation: "阅读翻译模型（或主对话模型）"
    case .cheap: "廉价批量模型"
    case .suggestion: "建议回复模型"
    case .proactiveAnnotation: "主动段评模型（或批量任务 cheap 模型）"
    case .embedding: "Embedding 模型"
    case .rerank: "重排模型"
    case .tts: "TTS 模型"
    case .image: "生图模型"
    }
  }
  private func normalizeEndpointPath(_ path: String) -> String {
    let v = path.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
      in: CharacterSet(charactersIn: "/"))
    return v.isEmpty ? "" : "/" + v
  }
  private func normalizeProviderBaseURL(_ raw: String) throws -> String {
    do { return try NetworkEndpointPolicy.normalizedServiceBaseURL(raw) }
    catch { throw ValidationError(error.localizedDescription) }
  }
  private func nowMillis() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
  struct ValidationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }

  private static func provider(_ row: [String: SQLValue]) -> AIProviderRecord? {
    guard let id = row["id"]?.int64 else { return nil }
    let dialect = ApiDialect(rawValue: row["apiFormat"]?.string ?? "") ?? .openAI
    let adapter = AiProviderAdapter(rawValue: row["adapter"]?.string ?? "") ?? .custom
    return AIProviderRecord(
      id: id, name: row["name"]?.string ?? "", baseURL: row["baseUrl"]?.string ?? "",
      apiKeyAlias: row["apiKeyAlias"]?.string ?? "", type: row["type"]?.string ?? "CHAT",
      extraJSON: row["extraJson"]?.string ?? "{}", apiFormat: dialect, adapter: adapter,
      createdAt: row["createdAt"]?.int64 ?? 0)
  }
  private static func model(_ row: [String: SQLValue]) -> AIModelRecord? {
    guard let id = row["id"]?.int64, let providerId = row["providerId"]?.int64 else { return nil }
    let type = AiModelType(rawValue: row["type"]?.string ?? "") ?? .chat
    return AIModelRecord(
      id: id, providerId: providerId, modelName: row["modelName"]?.string ?? "", type: type,
      chatApiFormat: row["chatApiFormat"]?.string ?? "", endpointPath: row["endpointPath"]?.string ?? "",
      extraJSON: row["extraJson"]?.string ?? "{}", createdAt: row["createdAt"]?.int64 ?? 0)
  }
}

struct ResolvedChatClient: Sendable {
  let client: any AIProtocolClient
  let options: ChatOptions
  let provider: AIProviderRecord
  let modelName: String
}

enum AIClientFactory {
  static func forRole(_ role: ModelRole) async throws -> ResolvedChatClient {
    let pair = try await AIProviderRepository.shared.resolve(role)
    return try forModel(provider: pair.0, model: pair.1)
  }

  static func forModel(provider: AIProviderRecord, model: AIModelRecord) throws
    -> ResolvedChatClient
  {
    let key = AIProviderRepositoryKeychain.key(for: provider)
    guard !key.isEmpty else { throw AIClientError.unsupported("\(provider.name) 缺少 API Key") }
    let merged = RequestOverrides.merge(provider: provider.extraJSON, model: model.extraJSON)
    let route = ProviderProtocolPolicy.route(provider: provider, model: model)
    let dialect: ApiDialect
    switch route {
    case .chat(let v), .embedding(let v): dialect = v
    case .unsupported(let reason): throw AIClientError.unsupported(reason)
    case .rerank: throw AIClientError.unsupported("重排模型请通过专用客户端调用")
    case .media: throw AIClientError.unsupported("媒体模型请通过专用客户端调用")
    }
    let chatEndpoint = if case .chat = route { model.endpointPath } else { "" }
    let embeddingEndpoint = if case .embedding = route { model.endpointPath } else { "" }
    let client: any AIProtocolClient =
      switch dialect {
      case .openAI:
        OpenAICompatibleClient(
          baseURL: provider.baseURL, apiKey: key, model: model.modelName,
          chatEndpointPath: chatEndpoint, embeddingEndpointPath: embeddingEndpoint,
          extraJSON: merged)
      case .openAIResponses:
        OpenAIResponsesClient(
          baseURL: provider.baseURL, apiKey: key, model: model.modelName,
          endpointPath: chatEndpoint, embeddingEndpointPath: embeddingEndpoint, extraJSON: merged)
      case .claude:
        ClaudeClient(
          baseURL: provider.baseURL, apiKey: key, model: model.modelName,
          endpointPath: chatEndpoint, extraJSON: merged)
      case .gemini:
        GeminiClient(
          baseURL: provider.baseURL, apiKey: key, model: model.modelName, extraJSON: merged)
      }
    return .init(
      client: client, options: .fromExtraJSON(merged), provider: provider,
      modelName: model.modelName)
  }
}

private enum AIProviderRepositoryKeychain {
  static func key(for provider: AIProviderRecord) -> String {
    KeychainStore.get(account: provider.apiKeyAlias)
  }
}
