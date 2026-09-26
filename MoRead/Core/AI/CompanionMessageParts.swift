import Foundation

enum CompanionMessagePart:Hashable,Sendable{case text(String),voice(String)}
enum CompanionMessageParser{
    static let maxVoiceParts=2
    static func parse(_ content:String,multiBubble:Bool)->[CompanionMessagePart]{
        let lines=content.components(separatedBy:.newlines);var raw:[(CompanionMessagePart,Bool)]=[];var textBuffer:[String]=[];var blank=false;var markedBlock=false;var block:[String]=[]
        func flushText(){let text=textBuffer.joined(separator:"\n").trimmingCharacters(in:.newlines);if !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{raw.append((.text(text),blank));blank=false};textBuffer=[]}
        for original in lines{let line=original.trimmingCharacters(in:.whitespaces);let marker=normalizedMarker(line);if markedBlock{if marker=="[/整段]" || marker=="[/block]"{markedBlock=false;let v=block.joined(separator:"\n").trimmingCharacters(in:.newlines);if !v.isEmpty{raw.append((.text(v),blank));blank=false};block=[]}else{block.append(original)};continue};if marker=="[整段]" || marker=="[block]"{flushText();markedBlock=true;continue};if line.isEmpty{flushText();blank=true;continue};if let spoken=voiceText(line){flushText();if !spoken.isEmpty{raw.append((.voice(spoken),blank));blank=false};continue};if isContinuation(line),!textBuffer.isEmpty{textBuffer.append(original)}else{flushText();textBuffer.append(original)}};if markedBlock{let v=block.joined(separator:"\n").trimmingCharacters(in:.newlines);if !v.isEmpty{raw.append((.text(v),blank))}};flushText()
        var voiceCount=0;let capped=raw.map{part,blank->(CompanionMessagePart,Bool) in if case .voice(let text)=part{voiceCount += 1;if voiceCount>maxVoiceParts{return(.text(text),blank)}};return(part,blank)}
        guard !multiBubble else{return capped.map(\.0)};var result:[CompanionMessagePart]=[],buffer="";for(part,precededBlank) in capped{switch part{case .text(let t):if !buffer.isEmpty{buffer += precededBlank ? "\n\n":"\n"};buffer += t;case .voice(let t):if !buffer.isEmpty{result.append(.text(buffer));buffer=""};result.append(.voice(t))}};if !buffer.isEmpty{result.append(.text(buffer))};return result
    }
    private static func voiceText(_ line:String)->String?{for marker in ["[[语音]]","[[voice]]","[语音]","[voice]"] where line.lowercased().hasPrefix(marker.lowercased()){return String(line.dropFirst(marker.count)).trimmingCharacters(in:.whitespacesAndNewlines)};return nil}
    private static func normalizedMarker(_ line:String)->String{line.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"：:。. ")).replacingOccurrences(of:"[[",with:"[").replacingOccurrences(of:"]]",with:"]")}
    private static func isContinuation(_ line:String)->Bool{let t=line.trimmingCharacters(in:.whitespaces);if ["|","> ","- ","* ","+ "].contains(where:{t.hasPrefix($0)}){return true};return t.range(of:"^\\d{1,3}[.)]\\s",options:.regularExpression) != nil}
}

struct CompanionAttachment:Codable,Hashable,Sendable,Identifiable{
    enum Kind:String,Codable,Sendable{case image,audio}
    var id:String=UUID().uuidString;var kind:Kind;var path:String;var title:String="";var text:String=""
}
