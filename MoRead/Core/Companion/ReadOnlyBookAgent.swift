import Foundation

actor ReadOnlyBookAgent {
    static let shared = ReadOnlyBookAgent()
    private let allowed = Set(["search_book","grep_book","read_chapter","list_annotations","list_notes"])

    func run(bookId:Int64,scope:ReadingScope,personaId:Int64?,messages:[AIChatMessage],maxRounds:Int=5) async throws -> String {
        let toolset=CompanionToolset(bookId:bookId,scope:scope,personaId:personaId,imageEnabled:false,webEnabled:false)
        let specs=toolset.specs.filter{allowed.contains($0.name)}
        let resolved=try await AIClientFactory.forRole(.chat)
        var history=GlobalPromptInjector.inject(messages:messages,presets:await MainActor.run{GlobalPromptPresetStore.shared.presets})
        var final=""
        for _ in 0..<maxRounds {
            var text="",calls:[ToolCall]=[]
            for try await delta in resolved.client.chatStream(messages:history,tools:specs,options:resolved.options){
                switch delta{case .text(let c):text += c;case .toolCalls(let c):calls=c;default:break}
            }
            final += text
            if calls.isEmpty { break }
            history.append(.init(role:.assistant,content:text,toolCalls:calls))
            for call in calls where allowed.contains(call.name){history.append(.init(role:.tool,content:try await toolset.execute(call),toolCallId:call.id))}
        }
        guard !final.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw AIClientError.empty}
        return final
    }
}
