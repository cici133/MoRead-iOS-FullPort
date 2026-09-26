import Foundation

struct SentenceSpan: Equatable, Hashable, Sendable {
    let start: Int
    let end: Int
    var length: Int { end - start }
    func contains(_ offset: Int) -> Bool { offset >= start && offset < end }
}

enum SentenceSegmenter {
    static let defaultMaxChars = 96
    private static let objectReplacement: UInt16 = 0xFFFC
    private static let terminators = Set("。！？!?…；;".utf16)
    private static let closers = Set("」』”’\"'）)】]〕〉》".utf16)
    private static let softBreaks = Set("，,、：: 　".utf16)

    static func segment(_ body: String, maxChars: Int = defaultMaxChars) -> [SentenceSpan] {
        let units = Array(body.utf16); guard !units.isEmpty else { return [] }
        var output: [SentenceSpan] = []; var lineStart = 0
        while lineStart <= units.count {
            let newline = units[lineStart...].firstIndex(of: 0x000A) ?? units.count
            splitLine(units, from: lineStart, to: newline, maxChars: max(1, maxChars), output: &output)
            if newline == units.count { break }; lineStart = newline + 1
        }
        return output
    }

    static func segmentParagraphs(_ body: String, maxChars: Int = 400) -> [SentenceSpan] {
        precondition(maxChars > 0, "maxChars 必须大于 0")
        let units=Array(body.utf16);guard !units.isEmpty else{return []};var out:[SentenceSpan]=[];var lineStart=0
        while lineStart <= units.count {
            let newline=units[lineStart...].firstIndex(of:0x000A) ?? units.count;var start=lineStart,end=newline
            while start<end && isIgnorable(units[start]){start += 1};while end>start && isIgnorable(units[end-1]){end -= 1}
            if start<end { if end-start<=maxChars{out.append(.init(start:start,end:end))}else{let sub=String(decoding:units[start..<end],as:UTF16.self);for span in segment(sub,maxChars:maxChars){out.append(.init(start:start+span.start,end:start+span.end))}} }
            if newline==units.count{break};lineStart=newline+1
        }
        return out
    }

    static func segmentChapter(_ body:String,maxChars:Int=2000)->[SentenceSpan]{
        let paragraphs=segmentParagraphs(body,maxChars:maxChars);guard let first=paragraphs.first else{return []};var result:[SentenceSpan]=[];var start=first.start,end=first.end
        for paragraph in paragraphs.dropFirst(){if paragraph.end-start<=maxChars{end=paragraph.end}else{result.append(.init(start:start,end:end));start=paragraph.start;end=paragraph.end}}
        result.append(.init(start:start,end:end));return result
    }

    static func indexAt(_ spans:[SentenceSpan],offset:Int)->Int{spans.firstIndex(where:{$0.end>offset}) ?? spans.count}

    static func speakableText(_ body:String,start:Int,end:Int)->String{
        let units=Array(body.utf16);guard start>=0,start<end,end<=units.count else{return ""};let cleaned=units[start..<end].map{$0==objectReplacement ? UInt16(0x20):$0};return String(decoding:cleaned,as:UTF16.self).trimmingCharacters(in:.whitespacesAndNewlines)
    }

    private static func splitLine(_ body:[UInt16],from:Int,to:Int,maxChars:Int,output:inout[SentenceSpan]){
        var start=from,i=from
        while i<to {if terminators.contains(body[i]){var end=i+1;while end<to && (terminators.contains(body[end]) || closers.contains(body[end])){end += 1};addClamped(body,start,end,maxChars,&output);start=end;i=end}else{i += 1}}
        if start<to{addClamped(body,start,to,maxChars,&output)}
    }
    private static func addClamped(_ body:[UInt16],_ rawStart:Int,_ rawEnd:Int,_ maxChars:Int,_ output:inout[SentenceSpan]){
        var start=rawStart,end=rawEnd;while start<end && isIgnorable(body[start]){start += 1};while end>start && isIgnorable(body[end-1]){end -= 1};guard start<end else{return};var cursor=start
        while end-cursor>maxChars {let windowEnd=cursor+maxChars;var cut = -1;var k=windowEnd;let floor=cursor+maxChars/3;while k>floor{if softBreaks.contains(body[k-1]){cut=k;break};k -= 1};if cut<0{cut=windowEnd};emitTrimmed(body,cursor,cut,&output);cursor=cut}
        emitTrimmed(body,cursor,end,&output)
    }
    private static func emitTrimmed(_ body:[UInt16],_ rawStart:Int,_ rawEnd:Int,_ output:inout[SentenceSpan]){var start=rawStart,end=rawEnd;while start<end && isIgnorable(body[start]){start += 1};while end>start && isIgnorable(body[end-1]){end -= 1};if start<end{output.append(.init(start:start,end:end))}}
    private static func isIgnorable(_ unit:UInt16)->Bool{if unit==objectReplacement{return true};guard let scalar=UnicodeScalar(Int(unit)) else{return false};return CharacterSet.whitespacesAndNewlines.contains(scalar)}
}
