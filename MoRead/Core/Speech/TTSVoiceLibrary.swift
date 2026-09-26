import AVFoundation
import Foundation

struct TTSVoiceRecord:Identifiable,Hashable,Sendable{var id:Int64=0;var voiceId:String;var displayName:String;var tags:String;var gender:String;var providerHint:String;var extraJSON:String="{}";var pinned:Bool=false;var sortOrder:Int=0}

actor TTSVoiceLibrary{
    static let shared=TTSVoiceLibrary();private let db=MoReadDatabase.shared
    func voices()async throws->[TTSVoiceRecord]{try await db.rows("SELECT * FROM tts_voices ORDER BY pinned DESC,sortOrder,id").compactMap(Self.row)}
    func save(_ v:TTSVoiceRecord)async throws->Int64{let id=v.voiceId.trimmingCharacters(in:.whitespacesAndNewlines),name=v.displayName.trimmingCharacters(in:.whitespacesAndNewlines);guard !id.isEmpty,!name.isEmpty else{throw CloudSpeechError.invalid("音色 ID 和名称不能为空")};let tags=v.tags.split(whereSeparator:{$0=="," || $0=="，"}).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty};if v.id>0{try await db.execute("UPDATE tts_voices SET voiceId=?,displayName=?,tags=?,gender=?,providerHint=?,extraJson=?,pinned=?,sortOrder=? WHERE id=?",[.text(id),.text(name),.text(Array(Set(tags)).joined(separator:",")),.text(v.gender),.text(v.providerHint),.text(v.extraJSON),.integer(v.pinned ? 1:0),.integer(Int64(v.sortOrder)),.integer(v.id)]);return v.id};return try await db.execute("INSERT INTO tts_voices(voiceId,displayName,tags,gender,providerHint,extraJson,pinned,sortOrder) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(providerHint,voiceId) DO UPDATE SET displayName=excluded.displayName,tags=excluded.tags,gender=excluded.gender,extraJson=excluded.extraJson",[.text(id),.text(name),.text(Array(Set(tags)).joined(separator:",")),.text(v.gender),.text(v.providerHint),.text(v.extraJSON),.integer(v.pinned ? 1:0),.integer(Int64(v.sortOrder))])}
    func delete(id:Int64)async throws{try await db.execute("DELETE FROM tts_voices WHERE id=?",[.integer(id)])}
    func ensurePresets()async throws{
        let existing=try await voices();let keys=Set(existing.map{"\($0.providerHint):\($0.voiceId)"})
        var presets:[TTSVoiceRecord]=[]
        let gemini=[("Zephyr","明亮"),("Puck","轻快"),("Charon","解说"),("Kore","坚定"),("Fenrir","热情"),("Leda","年轻"),("Orus","坚定"),("Aoede","轻盈"),("Callirrhoe","随和"),("Autonoe","明亮"),("Enceladus","气声"),("Iapetus","清晰"),("Umbriel","随和"),("Algieba","顺滑"),("Despina","顺滑"),("Erinome","清晰"),("Algenib","沙哑"),("Rasalgethi","解说"),("Laomedeia","轻快"),("Achernar","柔和"),("Alnilam","坚定"),("Schedar","平稳"),("Gacrux","成熟"),("Pulcherrima","鲜明"),("Achird","亲切"),("Zubenelgenubi","随性"),("Vindemiatrix","温柔"),("Sadachbia","活泼"),("Sadaltager","博学"),("Sulafat","温暖")]
        presets += gemini.enumerated().map{.init(voiceId:$0.element.0,displayName:"\($0.element.0) · \($0.element.1)",tags:"Gemini,多语言,\($0.element.1)",gender:"UNSPECIFIED",providerHint:"GEMINI",sortOrder:$0.offset)}
        let openAI=["alloy","ash","ballad","coral","echo","fable","onyx","nova","sage","shimmer","verse"]
        presets += openAI.enumerated().map{.init(voiceId:$0.element,displayName:$0.element.capitalized,tags:"OpenAI",gender:"UNSPECIFIED",providerHint:"OPENAI",sortOrder:$0.offset)}
        presets += [
            .init(voiceId:"male-qn-qingse",displayName:"青涩青年男声",tags:"男声,青年,对白",gender:"MALE",providerHint:"MINIMAX"),
            .init(voiceId:"male-qn-jingying",displayName:"精英青年男声",tags:"男声,沉稳,旁白",gender:"MALE",providerHint:"MINIMAX"),
            .init(voiceId:"female-shaonv",displayName:"少女女声",tags:"女声,年轻,温柔",gender:"FEMALE",providerHint:"MINIMAX")]
        for p in presets where !keys.contains("\(p.providerHint):\(p.voiceId)"){_ = try await save(p)}
    }
    func refreshGeminiCatalog()async throws->Int{
        let config=await MainActor.run{TTSSettingsStore.shared.settings};let key=await MainActor.run{TTSSettingsStore.shared.currentKey()};guard config.aiProvider == .gemini,!key.isEmpty else{throw CloudSpeechError.invalid("请先配置 Gemini TTS")};let base:String;do{base=try NetworkEndpointPolicy.normalizedServiceBaseURL(config.aiBaseURL)}catch{throw CloudSpeechError.invalid(error.localizedDescription)};guard let url=URL(string:base+"/voices?page_size=1000") else{throw CloudSpeechError.invalid("Gemini 音色地址无效")};var req=URLRequest(url:url);req.setValue(key,forHTTPHeaderField:"x-goog-api-key");let(data,response)=try await URLSession.shared.data(for:req);guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else{throw CloudSpeechError.invalid(String(data:data,encoding:.utf8) ?? "Gemini 音色目录请求失败")};guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],let values=root["voices"] as? [[String:Any]] else{throw CloudSpeechError.invalid("Gemini 音色目录格式无效")};var count=0;for (i,item) in values.enumerated(){guard let id=item["id"] as? String,!id.isEmpty else{continue};let name=(item["display_name"] as? String)?.nilIfEmpty ?? id;let tags=["Gemini",item["language_code"] as? String,item["persona"] as? String,item["pitch"] as? String].compactMap{$0}.filter{!$0.isEmpty}.joined(separator:",");_ = try await save(.init(voiceId:id,displayName:name,tags:tags,gender:(item["gender"] as? String)?.uppercased() ?? "UNSPECIFIED",providerHint:"GEMINI",sortOrder:i));count += 1};return count
    }
    private static func row(_ r: [String: SQLValue]) -> TTSVoiceRecord? {
        guard let id = r["id"]?.int64 else { return nil }
        let voiceId = r["voiceId"]?.string ?? ""
        let displayName = r["displayName"]?.string ?? ""
        let tags = r["tags"]?.string ?? ""
        let gender = r["gender"]?.string ?? ""
        let providerHint = r["providerHint"]?.string ?? ""
        let extraJSON = r["extraJson"]?.string ?? "{}"
        let pinned = (r["pinned"]?.int64 ?? 0) != 0
        let sortOrder = Int(r["sortOrder"]?.int64 ?? 0)
        return TTSVoiceRecord(
            id: id,
            voiceId: voiceId,
            displayName: displayName,
            tags: tags,
            gender: gender,
            providerHint: providerHint,
            extraJSON: extraJSON,
            pinned: pinned,
            sortOrder: sortOrder
        )
    }
}
private extension String{var nilIfEmpty:String?{isEmpty ? nil:self}}
