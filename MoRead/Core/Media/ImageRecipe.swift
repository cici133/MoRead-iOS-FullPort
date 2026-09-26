import Foundation

struct StyleSpec: Codable, Hashable, Sendable {
    var presetId = "watercolor"
    var natural = "soft watercolor illustration, muted palette, paper texture, gentle light"
    var tags = "watercolor, illustration, muted colors, paper texture, soft lighting"
    var negative = "text, watermark, lowres"
    var seed: Int64? = nil
    var referenceIds: [String] = []
    var referenceStrength: Double = 0.6
    var informationExtracted: Double = 1.0
}
struct LookAttribute: Codable, Hashable, Sendable { var label:String;var value:String;var chapterIndex:Int?;var start:Int?;var end:Int?;var quote:String="" }
struct LookSpec: Codable, Hashable, Identifiable, Sendable {
    var id:String;var characterKey:String;var name:String;var sinceChapter:Int=0;var natural:String="";var tags:String="";var attributes:[LookAttribute]=[];var referenceIds:[String]=[];var referenceStrength:Double=0.6;var fidelity:Double=1;var source:String="manual"
}
struct ShotSpec: Codable, Hashable, Sendable {
    var cast:[String]=[];var action:String="";var setting:String="";var composition:String="";var lighting:String="";var mood:String=""
    var text:String{[action,setting,composition,lighting,mood].filter{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}.joined(separator:", ")}
}
enum ReferenceKind:String,Codable,Hashable,Sendable{case character="CHARACTER",style="STYLE"}
struct ReferenceSpec:Codable,Hashable,Sendable{var assetId:String;var kind:ReferenceKind;var characterKey:String?=nil;var strength:Double=0.6;var informationExtracted:Double=1;var fidelity:Double=1}
struct ImageRecipe:Codable,Hashable,Sendable{var version=1;var style=StyleSpec();var cast:[LookSpec]=[];var shot=ShotSpec();var references:[ReferenceSpec]=[];var seed:Int64?=nil;var size:String?=nil;var backend:String="";var promptOverride:String=""}

struct ImageCapabilities:Sendable{var maxReferences=0;var maxCharacterReferences=0;var maxCharacters=Int.max;var perCharacterPrompt=false;var seed=false;var vibe=false;var exclusiveCharacterAndStyle=false;var characterReferenceCost=0;var tags=false;var multilingual=false}
enum ReferenceNotice:String,Codable,Sendable{case textOnly,primaryCharacterOnly,referenceLimit,vibeWithoutCharacter,seedUnsupported}
struct ReferencePlan:Sendable{var references:[ReferenceSpec];var notices:[ReferenceNotice];var extraCostPerImage:Int}

enum ImageRecipeLogic {
    static func planReferences(capabilities:ImageCapabilities,cast:[LookSpec],style:StyleSpec,enabled:Bool=true)->ReferencePlan{
        guard enabled else{return .init(references:[],notices:[],extraCostPerImage:0)}
        let people=cast.compactMap{look in look.referenceIds.first.map{ReferenceSpec(assetId:$0,kind:.character,characterKey:look.characterKey,strength:look.referenceStrength,fidelity:look.fidelity)}}
        let styles=style.referenceIds.prefix(3).map{ReferenceSpec(assetId:$0,kind:.style,strength:style.referenceStrength,informationExtracted:style.informationExtracted)}
        var notices:[ReferenceNotice]=[]
        guard capabilities.maxReferences>0 else{if !people.isEmpty || !styles.isEmpty{notices.append(.textOnly)};return .init(references:[],notices:notices,extraCostPerImage:0)}
        let selectedPeople=Array(people.prefix(capabilities.maxCharacterReferences));if people.count>selectedPeople.count{notices.append(.primaryCharacterOnly)}
        let selectedStyles:[ReferenceSpec]
        if !selectedPeople.isEmpty && capabilities.exclusiveCharacterAndStyle{if !styles.isEmpty{notices.append(.vibeWithoutCharacter)};selectedStyles=[]}else{selectedStyles=Array(styles)}
        let ordered=Array(selectedPeople.prefix(1))+selectedStyles+Array(selectedPeople.dropFirst())
        var seen=Set<String>();var selected:[ReferenceSpec]=[]
        for r in ordered where selected.count<capabilities.maxReferences {let k="\(r.kind.rawValue):\(r.assetId)";if seen.insert(k).inserted{selected.append(r)}}
        if selected.count<ordered.count{notices.append(.referenceLimit)}
        let styleTotal=max(1,selected.filter{$0.kind == .style}.reduce(0){$0+$1.strength})
        if capabilities.vibe{selected=selected.map{var r=$0;if r.kind == .style{r.strength/=styleTotal};return r}}
        return .init(references:selected,notices:notices,extraCostPerImage:selected.filter{$0.kind == .character}.count*capabilities.characterReferenceCost)
    }
    static func visibleLook(_ looks:[LookSpec],characterKey:String,chapterIndex:Int)->LookSpec?{looks.filter{$0.characterKey==characterKey && $0.sinceChapter<=chapterIndex}.sorted{a,b in a.sinceChapter==b.sinceChapter ? a.id>b.id:a.sinceChapter>b.sinceChapter}.first}
    static func assemble(_ recipe:ImageRecipe,capabilities:ImageCapabilities)->(prompt:String,negative:String){
        let style=capabilities.tags ? (recipe.style.tags.isEmpty ? recipe.style.natural:recipe.style.tags):(recipe.style.natural.isEmpty ? recipe.style.tags:recipe.style.natural)
        let people=recipe.cast.map{capabilities.tags ? ($0.tags.isEmpty ? $0.natural:$0.tags):$0.natural}
        let base=[style,recipe.shot.text].filter{!$0.isEmpty}.joined(separator:", ")
        let natural=(["Style: \(style)"]+zip(recipe.cast,people).map{"Character \($0.0.name): \($0.1)"}+["Scene (preserve the character descriptions above): \(recipe.shot.text)"]+(recipe.style.negative.isEmpty ? []:["Avoid: \(recipe.style.negative)"])).joined(separator:"\n")
        let prompt=recipe.promptOverride.isEmpty ? (!capabilities.tags ? natural:(capabilities.perCharacterPrompt ? base:([base]+people).filter{!$0.isEmpty}.joined(separator:", "))):recipe.promptOverride
        return(prompt,recipe.style.negative)
    }
    static func encode(_ value:ImageRecipe)throws->String{String(decoding:try JSONEncoder().encode(value),as:UTF8.self)}
    static func decode(_ raw:String)->ImageRecipe?{guard let d=raw.data(using:.utf8) else{return nil};return try? JSONDecoder().decode(ImageRecipe.self,from:d)}
}
