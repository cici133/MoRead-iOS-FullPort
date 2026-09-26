import SwiftUI

struct AICreationRequest: Identifiable {
    var id=UUID(); var type:AICreationType; var start:Int; var end:Int; var selectedText:String
}

struct AICreationView: View {
    let book:Book; let chapter:Chapter; let chapterText:String; let request:AICreationRequest
    @Environment(\.dismiss) private var dismiss
    @State private var directive="";@State private var creationId:Int64?;@State private var versions:[AICreationVersionRecord]=[];@State private var selectedVersion:Int64?;@State private var running=false;@State private var error:String?
    var body:some View{NavigationStack{List{Section(request.type == .rewrite ? "改写原文":"续写锚点"){if !request.selectedText.isEmpty{Text(request.selectedText).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)};TextField("方向，例如：更克制、更紧张、从另一个角度……",text:$directive,axis:.vertical);Button(running ? "生成中…":"生成新版本"){generate()}.disabled(running)};if !versions.isEmpty{Section("版本"){ForEach(versions){v in VStack(alignment:.leading,spacing:8){HStack{Text("版本 \(v.ord+1)").font(.headline);Spacer();if selectedVersion==v.id{Image(systemName:"checkmark.circle.fill")}};Text(v.directive).font(.caption).foregroundStyle(.secondary);Text(v.content).textSelection(.enabled);HStack{Button("设为当前"){Task{if let creationId{try? await AICreationRepository.shared.activate(creationId:creationId,versionId:v.id);selectedVersion=v.id}}};Button("继续写"){continueVersion(v)}}}.padding(.vertical,6)}}}}.navigationTitle(request.type == .rewrite ? "AI 改写":"AI 续写").toolbar{ToolbarItem(placement:.cancellationAction){Button("关闭"){dismiss()}}}.alert("创作失败",isPresented:Binding(get:{error != nil},set:{if !$0{error=nil}})){Button("好",role:.cancel){}}message:{Text(error ?? "")}}}
    private func generate(){running=true;Task{@MainActor in do{let id=try await AICreationService.shared.generate(book:book,chapter:chapter,body:chapterText,type:request.type,start:request.start,end:request.end,directive:directive,creationId:creationId);creationId=id;versions=try await AICreationRepository.shared.versions(creationId:id);selectedVersion=versions.last?.id}catch{self.error=error.localizedDescription};running=false}}
    private func continueVersion(_ version:AICreationVersionRecord){guard let cid=creationId else{return};running=true;Task{@MainActor in do{let creations=try await AICreationRepository.shared.creations(bookId:book.id,chapterIndex:chapter.chapterIndex);guard let c=creations.first(where:{$0.id==cid}) else{return};try await AICreationService.shared.continueVersion(creation:c,version:version,book:book,chapter:chapter,directive:directive);versions=try await AICreationRepository.shared.versions(creationId:cid)}catch{self.error=error.localizedDescription};running=false}}
}
