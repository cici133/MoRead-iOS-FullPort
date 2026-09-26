import Foundation
import CryptoKit

actor ParagraphTranslationRepository {
    static let shared = ParagraphTranslationRepository()
    private func root() throws -> URL { let u=try MoReadDatabase.applicationDirectory().appendingPathComponent("reader-custom/translations",isDirectory:true);try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true);return u }
    private func file(bookId:Int64,chapterIndex:Int)throws->URL{try root().appendingPathComponent("\(bookId)-\(chapterIndex).json")}

    func translations(bookId:Int64,chapterIndex:Int,source:String)throws->[ParagraphTranslationRecord]{
        guard let data=try? Data(contentsOf:file(bookId:bookId,chapterIndex:chapterIndex)),let rows=try? JSONDecoder().decode([ParagraphTranslationRecord].self,from:data) else{return []}
        let ns=source as NSString
        return rows.filter{r in guard r.start>=0,r.end>r.start,r.end<=ns.length else{return false};return Self.hash(ns.substring(with:NSRange(location:r.start,length:r.end-r.start)))==r.sourceHash}
    }

    func save(bookId:Int64,chapterIndex:Int,start:Int,end:Int,source:String,translation:String,modelKey:String)throws{
        let ns=source as NSString;guard start>=0,end>start,end<=ns.length else{throw TranslationError.invalidRange}
        var rows=try translations(bookId:bookId,chapterIndex:chapterIndex,source:source)
        let hash=Self.hash(ns.substring(with:NSRange(location:start,length:end-start)))
        rows.removeAll{$0.start==start && $0.end==end}
        rows.append(.init(bookId:bookId,chapterIndex:chapterIndex,start:start,end:end,sourceHash:hash,translatedText:translation,modelKey:modelKey,createdAt:Int64(Date().timeIntervalSince1970*1000),hidden:nil))
        let f=try file(bookId:bookId,chapterIndex:chapterIndex);try JSONEncoder().encode(rows.sorted{$0.start<$1.start}).write(to:f,options:.atomic)
    }

    func remove(bookId:Int64,chapterIndex:Int,start:Int,end:Int,source:String)throws{var rows=try translations(bookId:bookId,chapterIndex:chapterIndex,source:source);rows.removeAll{$0.start==start && $0.end==end};let f=try file(bookId:bookId,chapterIndex:chapterIndex);try JSONEncoder().encode(rows).write(to:f,options:.atomic)}
    func setHidden(bookId:Int64,chapterIndex:Int,start:Int,end:Int,source:String,hidden:Bool)throws{
        var rows=try translations(bookId:bookId,chapterIndex:chapterIndex,source:source)
        guard let index=rows.firstIndex(where:{$0.start==start && $0.end==end}) else{return}
        rows[index].hidden=hidden
        let f=try file(bookId:bookId,chapterIndex:chapterIndex);try JSONEncoder().encode(rows).write(to:f,options:.atomic)
    }
    static func hash(_ text:String)->String{SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()}
    enum TranslationError:Error{case invalidRange}
}

actor TranslationService {
    static let shared = TranslationService()
    func translate(_ text:String,targetLanguage:String="简体中文")async throws->String{
        let resolved=try await AIClientFactory.forRole(.translation)
        let messages=[AIChatMessage(role:.system,content:"你是阅读翻译器。忠实翻译，不补充解释；保留段落和专有名词。目标语言：\(targetLanguage)"),AIChatMessage(role:.user,content:text)]
        return try await resolved.client.chat(messages:messages,options:resolved.options)
    }
    func dictionaryEntry(word:String,context:String)throws->AIChatMessage{AIChatMessage(role:.user,content:"请解释词语「\(word)」。只输出 JSON：{\"label\":\"中文标注\",\"phonetic\":\"音标\",\"gloss\":\"词下短释义\",\"markdown\":\"详细释义\"}。语境：\(context.prefix(1200))")}
}
