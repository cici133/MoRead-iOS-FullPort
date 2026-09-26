import Foundation

protocol AIProtocolClient: Sendable {
    func chatStream(messages: [AIChatMessage], tools: [ToolSpec], options: ChatOptions) -> AsyncThrowingStream<ChatDelta, Error>
    func chat(messages: [AIChatMessage], options: ChatOptions) async throws -> String
    func embed(texts: [String]) async throws -> [[Float]]
}

private func multipartContent(_ message: AIChatMessage) -> Any {
    guard !message.parts.isEmpty else { return message.content }
    return message.parts.map { part -> [String:Any] in
        switch part {
        case let .text(text): return ["type":"text", "text":text]
        case let .image(base64,mime): return ["type":"image_url", "image_url":["url":"data:\(mime);base64,\(base64)"]]
        }
    }
}

private func openAIToolDefinition(_ tool: ToolSpec) -> [String:Any] {
    ["type":"function", "function":["name":tool.name,"description":tool.description,"parameters":tool.parameters]]
}

private func encodeOpenAIMessage(_ message: AIChatMessage) -> [String:Any] {
    var value: [String:Any] = ["role":message.role.rawValue]
    if message.role == .assistant, !message.toolCalls.isEmpty {
        value["content"] = message.content.isEmpty ? NSNull() : message.content
        value["tool_calls"] = message.toolCalls.map { call -> [String:Any] in
            var c: [String:Any] = ["id":call.id,"type":"function","function":["name":call.name,"arguments":call.arguments]]
            if let extra=call.extraContent { c["extra_content"] = jsonFoundation(extra) }
            return c
        }
        if let details=message.toolCalls.first?.reasoningDetails, !details.isEmpty { value["reasoning_details"] = details.map(jsonFoundation) }
    } else if message.role == .tool {
        value["content"] = message.content; if let id=message.toolCallId { value["tool_call_id"] = id }
    } else { value["content"] = multipartContent(message) }
    return value
}

private func jsonFoundation(_ value: [String:JSONValue]) -> [String:Any] { value.mapValues(jsonFoundation) }
private func jsonFoundation(_ value: JSONValue) -> Any {
    switch value { case .null:return NSNull(); case let .bool(v):return v; case let .number(v):return v; case let .string(v):return v; case let .array(v):return v.map(jsonFoundation); case let .object(v):return jsonFoundation(v) }
}

final class OpenAICompatibleClient: AIProtocolClient, @unchecked Sendable {
    let baseURL: String, apiKey: String, model: String, chatEndpointPath: String, embeddingEndpointPath: String
    let overrides: RequestOverrides
    init(baseURL:String,apiKey:String,model:String,chatEndpointPath:String="",embeddingEndpointPath:String="",extraJSON:String="{}") {
        self.baseURL=AIHTTP.normalizedBase(baseURL); self.apiKey=apiKey; self.model=model; self.chatEndpointPath=chatEndpointPath; self.embeddingEndpointPath=embeddingEndpointPath; self.overrides = .parse(extraJSON)
    }
    func chatStream(messages:[AIChatMessage],tools:[ToolSpec]=[],options:ChatOptions = .default)->AsyncThrowingStream<ChatDelta,Error>{
        AsyncThrowingStream { continuation in
            let task=Task {
                do {
                    let request=try buildChatRequest(messages:messages,tools:tools,options:options,stream:true)
                    var slots:[Int:(id:String,name:String,args:String,extra:[String:JSONValue]?)] = [:]
                    var reasoningDetails:[[String:JSONValue]]=[]
                    for try await event in AIHTTP.sse(for:request) {
                        if event.data == "[DONE]" { break }
                        guard let root=AIHTTP.jsonObject(event.data) else{continue}
                        if let usage=root["usage"] as? [String:Any] { continuation.yield(.usage(inputTokens:int64(usage["prompt_tokens"]),outputTokens:int64(usage["completion_tokens"]),totalTokens:int64(usage["total_tokens"]))) }
                        guard let choice=(root["choices"] as? [[String:Any]])?.first, let delta=choice["delta"] as? [String:Any] else{continue}
                        if let value=(delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !value.isEmpty { continuation.yield(.reasoning(value)) }
                        if let value=delta["content"] as? String, !value.isEmpty { continuation.yield(.text(value)) }
                        if let details=delta["reasoning_details"] as? [[String:Any]] { reasoningDetails += details.map(jsonValueObject) }
                        if let fragments=delta["tool_calls"] as? [[String:Any]] {
                            for fragment in fragments {
                                let index=(fragment["index"] as? NSNumber)?.intValue ?? (slots.keys.max() ?? 0)
                                var slot=slots[index] ?? ("","","",nil)
                                if let id=fragment["id"] as? String { slot.id=id }
                                if let fn=fragment["function"] as? [String:Any] { if let n=fn["name"] as? String {slot.name=n}; if let a=fn["arguments"] as? String {slot.args += a} }
                                if let extra=fragment["extra_content"] as? [String:Any] { slot.extra=jsonValueObject(extra) }
                                slots[index]=slot
                            }
                        }
                    }
                    if !slots.isEmpty {
                        let calls=slots.keys.sorted().map { i -> ToolCall in let s=slots[i]!; return .init(id:s.id,name:s.name,arguments:s.args,extraContent:s.extra,reasoningDetails:i==slots.keys.sorted().first ? reasoningDetails:[]) }
                        continuation.yield(.toolCalls(calls))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination={_ in task.cancel()}
        }
    }
    func chat(messages:[AIChatMessage],options:ChatOptions = .default) async throws -> String {
        let data=try await AIHTTP.data(for:buildChatRequest(messages:messages,tools:[],options:options,stream:false)); let root=try AIHTTP.jsonObject(data)
        guard let choice=(root["choices"] as? [[String:Any]])?.first, let msg=choice["message"] as? [String:Any], let text=msg["content"] as? String, !text.isEmpty else{throw AIClientError.empty}; return text
    }
    func embed(texts:[String]) async throws -> [[Float]] {
        guard !texts.isEmpty else{return []}; let path=embeddingEndpointPath.isEmpty ? "/embeddings" : embeddingEndpointPath
        let url=try AIHTTP.endpoint(base:baseURL,path:path); var body:[String:Any]=["model":model,"input":texts]; body=AIHTTP.merge(body,extras:overrides.body)
        let request=try AIHTTP.request(url:url,headers:headers(extra:[:]),json:body); let root=try AIHTTP.jsonObject(try await AIHTTP.data(for:request))
        guard let rows=root["data"] as? [[String:Any]], rows.count==texts.count else{throw AIClientError.malformed("embedding 数量与输入不一致")}
        return rows.sorted{int($0["index"])<int($1["index"])}.map { (($0["embedding"] as? [NSNumber]) ?? []).map{$0.floatValue} }
    }
    private func buildChatRequest(messages:[AIChatMessage],tools:[ToolSpec],options:ChatOptions,stream:Bool)throws->URLRequest{
        let path=chatEndpointPath.isEmpty ? "/chat/completions" : chatEndpointPath; let url=try AIHTTP.endpoint(base:baseURL,path:path)
        var body:[String:Any]=["model":model,"messages":messages.map(encodeOpenAIMessage),"stream":stream]
        if let v=options.temperature{body["temperature"]=v}; if let v=options.topP{body["top_p"]=v}; if let v=options.maxTokens{body["max_tokens"]=v}; if let v=options.reasoning{body["reasoning_effort"]=v.rawValue}
        if !tools.isEmpty{body["tools"]=tools.map(openAIToolDefinition)}; if stream{body["stream_options"]=["include_usage":true]}
        body=AIHTTP.merge(body,extras:overrides.body); body=AIHTTP.merge(body,extras:options.extraBody)
        return try AIHTTP.request(url:url,headers:headers(extra:options.extraHeaders),json:body)
    }
    private func headers(extra:[String:String])->[String:String]{ var h=overrides.headers; extra.forEach{h[$0]=$1}; if !apiKey.isEmpty{h["Authorization"]="Bearer \(apiKey)"}; return h }
}

final class OpenAIResponsesClient: AIProtocolClient, @unchecked Sendable {
    let baseURL:String,apiKey:String,model:String,endpointPath:String,embeddingEndpointPath:String; let overrides:RequestOverrides
    init(baseURL:String,apiKey:String,model:String,endpointPath:String="",embeddingEndpointPath:String="",extraJSON:String="{}") { self.baseURL=AIHTTP.normalizedBase(baseURL);self.apiKey=apiKey;self.model=model;self.endpointPath=endpointPath;self.embeddingEndpointPath=embeddingEndpointPath;self.overrides = .parse(extraJSON) }
    func chatStream(messages:[AIChatMessage],tools:[ToolSpec]=[],options:ChatOptions = .default)->AsyncThrowingStream<ChatDelta,Error>{
        AsyncThrowingStream{continuation in let task=Task{ do{
            let request=try buildRequest(messages:messages,tools:tools,options:options,stream:true); var calls:[String:(name:String,args:String)]=[:]
            for try await e in AIHTTP.sse(for:request){ if e.data=="[DONE]"{break}; guard let o=AIHTTP.jsonObject(e.data), let type=o["type"] as? String else{continue}
                switch type {
                case "response.output_text.delta": if let d=o["delta"] as? String{continuation.yield(.text(d))}
                case "response.reasoning_summary_text.delta": if let d=o["delta"] as? String{continuation.yield(.reasoning(d))}
                case "response.output_item.added": if let item=o["item"] as? [String:Any], item["type"] as? String=="function_call" { let id=(item["call_id"] as? String) ?? (item["id"] as? String) ?? UUID().uuidString; calls[id]=((item["name"] as? String) ?? "",(item["arguments"] as? String) ?? "") }
                case "response.function_call_arguments.delta": let id=(o["call_id"] as? String) ?? (o["item_id"] as? String) ?? ""; if var c=calls[id], let d=o["delta"] as? String{c.args += d;calls[id]=c}
                case "response.function_call_arguments.done": let id=(o["call_id"] as? String) ?? (o["item_id"] as? String) ?? ""; if var c=calls[id], let a=o["arguments"] as? String{c.args=a;calls[id]=c}
                case "response.completed": if let response=o["response"] as? [String:Any], let usage=response["usage"] as? [String:Any]{continuation.yield(.usage(inputTokens:int64(usage["input_tokens"]),outputTokens:int64(usage["output_tokens"]),totalTokens:int64(usage["total_tokens"])))}
                default: break }
            }
            if !calls.isEmpty{continuation.yield(.toolCalls(calls.map{ToolCall(id:$0.key,name:$0.value.name,arguments:$0.value.args)}))}; continuation.finish()
        }catch{continuation.finish(throwing:error)}}; continuation.onTermination={_ in task.cancel()} }
    }
    func chat(messages:[AIChatMessage],options:ChatOptions = .default) async throws -> String {
        var payload=try makePayload(messages:messages,tools:[],options:options,stream:false); var removals=0
        while true {
            do { let request=try request(payload:payload); let root=try AIHTTP.jsonObject(try await AIHTTP.data(for:request)); if let text=root["output_text"] as? String,!text.isEmpty{return text}; if let output=root["output"] as? [[String:Any]]{let t=output.flatMap{($0["content"] as? [[String:Any]]) ?? []}.compactMap{$0["text"] as? String}.joined();if !t.isEmpty{return t}};throw AIClientError.empty }
            catch let AIClientError.http(code,message) where (code==400||code==422) && removals<6 { guard let adjusted=removingRejectedResponsesParameter(payload:payload,errorBody:"{\"error\":{\"message\":\"\(message.replacingOccurrences(of:"\"",with:"\\\""))\"}}") else{throw AIClientError.http(code,message)};payload=adjusted;removals += 1 }
        }
    }
    func embed(texts:[String]) async throws -> [[Float]] { try await OpenAICompatibleClient(baseURL:baseURL,apiKey:apiKey,model:model,embeddingEndpointPath:embeddingEndpointPath,extraJSON:"{}").embed(texts:texts) }
    private func buildRequest(messages:[AIChatMessage],tools:[ToolSpec],options:ChatOptions,stream:Bool)throws->URLRequest{ try request(payload:makePayload(messages:messages,tools:tools,options:options,stream:stream)) }
    private func request(payload:[String:Any])throws->URLRequest{let path=endpointPath.isEmpty ? "/responses":endpointPath;let url=try AIHTTP.endpoint(base:baseURL,path:path);var h=overrides.headers;if !apiKey.isEmpty{h["Authorization"]="Bearer \(apiKey)"};return try AIHTTP.request(url:url,headers:h,json:payload)}
    private func makePayload(messages:[AIChatMessage],tools:[ToolSpec],options:ChatOptions,stream:Bool)throws->[String:Any]{
        let system=messages.filter{$0.role == .system}.map(\.content).joined(separator:"\n\n"); var input:[[String:Any]]=[]
        for m in messages where m.role != .system {
            if m.role == .tool { input.append(["type":"function_call_output","call_id":m.toolCallId ?? "","output":m.content]);continue }
            input.append(["role":m.role == .assistant ? "assistant":"user","content":[["type":m.role == .assistant ? "output_text":"input_text","text":m.content]]])
            if m.role == .assistant { for c in m.toolCalls{input.append(["type":"function_call","call_id":c.id,"name":c.name,"arguments":c.arguments])} }
        }
        var body:[String:Any]=["model":model,"input":input,"stream":stream,"store":false];if !system.isEmpty{body["instructions"]=system};if !tools.isEmpty{body["tools"]=tools.map{["type":"function","name":$0.name,"description":$0.description,"parameters":$0.parameters]}}
        if let v=options.temperature{body["temperature"]=v};if let v=options.topP{body["top_p"]=v};if let v=options.maxTokens{body["max_output_tokens"]=v};if let v=options.reasoning{body["reasoning"]=["effort":v.rawValue,"summary":"auto"]}
        body=AIHTTP.merge(body,extras:overrides.body);return AIHTTP.merge(body,extras:options.extraBody)
    }
}

private func int(_ value:Any?)->Int{(value as? NSNumber)?.intValue ?? 0}
private func int64(_ value:Any?)->Int64?{(value as? NSNumber)?.int64Value}
private func jsonValueObject(_ input:[String:Any])->[String:JSONValue]{input.mapValues(jsonValue)}
private func jsonValue(_ value:Any)->JSONValue{switch value{case is NSNull:return .null;case let v as Bool:return .bool(v);case let v as NSNumber:return .number(v.doubleValue);case let v as String:return .string(v);case let v as [Any]:return .array(v.map(jsonValue));case let v as [String:Any]:return .object(jsonValueObject(v));default:return .string(String(describing:value))}}
