import Foundation

enum AudiobookEngine:String,Codable,CaseIterable,Sendable{case system="SYSTEM",ai="AI"}
enum AudiobookRoleKind:String,Codable,CaseIterable,Sendable{case narrator="NARRATOR",character="CHARACTER"}
enum AudiobookChapterStatus:String,Codable,CaseIterable,Sendable{case none="NONE",scripted="SCRIPTED",confirmed="CONFIRMED",synthesizing="SYNTHESIZING",ready="READY",stale="STALE"}
enum AudiobookEnginePolicy:String,Codable,CaseIterable,Sendable{
    case allSystem="ALL_SYSTEM",narratorSystemCharactersAI="NARRATOR_SYSTEM_CHARACTERS_AI",allAI="ALL_AI",custom="CUSTOM"
    var label:String{switch self{case .allSystem:return"全部系统 TTS";case .narratorSystemCharactersAI:return"旁白系统 · 角色 AI";case .allAI:return"全部 AI TTS";case .custom:return"逐角色自定义"}}
    func engine(for kind:AudiobookRoleKind)->AudiobookEngine{switch self{case .allSystem:return .system;case .narratorSystemCharactersAI:return kind == .narrator ? .system:.ai;case .allAI:return .ai;case .custom:return .ai}}
}
struct AudiobookRole:Identifiable,Hashable,Sendable{var id:Int64=0;var bookId:Int64;var name:String;var aliases:[String];var kind:AudiobookRoleKind;var gender:String;var engine:AudiobookEngine;var voiceId:String;var extraJSON:String;var color:String;var sortOrder:Int;var source:String}
struct AudiobookSegment:Identifiable,Hashable,Sendable{var id:Int64=0;var bookId:Int64;var chapterIndex:Int;var start:Int;var end:Int;var roleId:Int64?;var emotion:String?;var instruction:String?;var audioPath:String?;var audioMillis:Int64;var revision:Int}
struct AudiobookChapterState:Hashable,Sendable{var bookId:Int64;var chapterIndex:Int;var state:String;var scriptedAt:Int64;var confirmedAt:Int64;var synthesizedAt:Int64;var segmentCount:Int;var readySegmentCount:Int;var totalMillis:Int64;var status:AudiobookChapterStatus{AudiobookChapterStatus(rawValue:state) ?? .none}}
struct AudiobookCostEstimate:Hashable,Sendable{var totalChars:Int;var segmentCount:Int;var aiSegmentCount:Int;var systemSegmentCount:Int;var estimatedCost:Double}
struct AudiobookProductionProgress:Hashable,Sendable{var chapterIndex:Int;var chapterTitle:String;var completedSegments:Int;var totalSegments:Int}
struct AudiobookProductionSummary:Hashable,Sendable{var completedSegments:Int;var totalSegments:Int;var readyChapters:Int}

enum AudiobookRevision {
    static func of(_ text:String)->Int { hash(text) }
    static func hash(_ text:String)->Int {
        var value:UInt32=2166136261
        for unit in text.utf16{value=(value ^ UInt32(unit)) &* 16777619}
        return Int(value & 0x7fff_ffff)
    }
}

enum AudiobookCostEstimator{
    static func estimate(characterCounts:[Int],engines:[AudiobookEngine],pricePerTenThousandChars:Double)->AudiobookCostEstimate{
        let size=min(characterCounts.count,engines.count);var total=0,aiChars=0,ai=0
        for i in 0..<size{let chars=max(0,characterCounts[i]);total += chars;if engines[i] == .ai{ai += 1;aiChars += chars}}
        return .init(totalChars:total,segmentCount:size,aiSegmentCount:ai,systemSegmentCount:size-ai,estimatedCost:Double(aiChars)/10000*max(0,pricePerTenThousandChars))
    }
}
