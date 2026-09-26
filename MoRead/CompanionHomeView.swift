import SwiftUI
import UIKit

struct CompanionHomeView: View {
    @State private var page = 0
    var body: some View {
        NavigationStack {
            Group {
                if page == 0 { LibraryCompanionView() }
                else { PersonaLibraryView() }
            }
            .navigationTitle(page == 0 ? "书库伴读" : "角色")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $page) {
                        Text("书库伴读").tag(0)
                        Text("角色").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }
            }
        }
    }
}

private struct LibraryCompanionView: View {
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var session = LibraryCompanionSession()
    @State private var input = ""
    @State private var showConversations = false
    @State private var showFocus = false
    @State private var showPersonas = false
    @State private var personas: [PersonaRecord] = []
    @State private var chatAppearance = PersonaChatAppearance()
    @State private var chatBackgroundPath: String?
    @State private var editingBubble: CompanionBubble?
    @State private var editDraft = ""

    private var selectedPersona: PersonaRecord? { personas.first { $0.id == session.selectedPersonaId } }

    var body: some View {
        PersonaChatBackdrop(appearance: chatAppearance, imagePath: chatBackgroundPath) {
        VStack(spacing: 0) {
            if !session.focusedBookIds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(session.focusedBookIds, id: \.self) { id in
                            if let book = library.books.first(where: { $0.id == id }) {
                                Text(book.title).font(.caption).padding(.horizontal,10).padding(.vertical,5).background(.thinMaterial,in:Capsule())
                            }
                        }
                    }.padding(.horizontal)
                }.padding(.vertical,6)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:12) {
                        if session.bubbles.isEmpty {
                            ContentUnavailableView("和整个书库聊聊", systemImage:"sparkles.rectangle.stack", description:Text("可以不选书直接聊天；需要原文时伴读会先查找书籍，再按需读取已读内容。"))
                                .padding(.top,60)
                        }
                        ForEach(session.bubbles) { bubble in
                            LibraryBubbleView(bubble:bubble, appearance:chatAppearance)
                                .id(bubble.id)
                                .contextMenu {
                                    if bubble.storedId != nil {
                                        Button("编辑") { editDraft=bubble.content; editingBubble=bubble }
                                        if bubble.role == .assistant { Button("重新生成") { Task { await session.reroll(bubble) } } }
                                        Button("从这里建立分支") { Task { await session.branch(at:bubble) } }
                                    }
                                }
                        }
                        ForEach(session.organizationPlans) { message in
                            LibraryOrganizationPlanCard(message:message) { apply in
                                Task {
                                    await session.confirmOrganization(messageId:message.messageId,apply:apply)
                                    if apply { try? await library.refresh() }
                                }
                            }
                        }
                    }.padding()
                }
                .onChange(of: session.bubbles.count) { _, _ in if let last=session.bubbles.last?.id { withAnimation { proxy.scrollTo(last,anchor:.bottom) } } }
            }
            Divider()
            HStack(alignment:.bottom,spacing:10) {
                TextField("问问伴读…",text:$input,axis:.vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                if session.isStreaming { Button { session.cancel() } label:{Image(systemName:"stop.fill")} }
                else { Button { let text=input;input="";session.send(text) } label:{Image(systemName:"arrow.up.circle.fill").font(.title2)}.disabled(input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
            }.padding()
        }
        }
        .toolbar {
            ToolbarItemGroup(placement:.topBarTrailing) {
                Button { showFocus=true } label:{Image(systemName:"books.vertical")}
                Button { showPersonas=true } label:{Image(systemName:"person.crop.circle")}
                Button { showConversations=true } label:{Image(systemName:"bubble.left.and.bubble.right")}
                Menu {
                    Button("重试上一条回复") { Task { await session.retryLast() } }
                    Button("新建话题") { Task { _ = try? await session.create() } }
                } label: { Image(systemName:"ellipsis.circle") }
            }
        }
        .task { await session.bootstrap(); await loadPersonas(); await loadChatAppearance() }
        .onChange(of: session.selectedPersonaId) { _, _ in Task { await loadChatAppearance() } }
        .sheet(isPresented:$showFocus) { FocusBooksSheet(selected:session.focusedBookIds,books:library.books) { session.setFocused($0);showFocus=false } }
        .sheet(isPresented:$showPersonas) { NavigationStack { PersonaPickerView(personas:personas,selection:session.selectedPersonaId) { id in
            showPersonas=false
            Task { await session.setPersona(id); await loadChatAppearance() }
        } } }
        .sheet(isPresented:$showConversations) { NavigationStack { ConversationPicker(session:session) } }
        .sheet(item:$editingBubble) { bubble in
            NavigationStack {
                Form { TextEditor(text:$editDraft).frame(minHeight:180) }
                    .navigationTitle(bubble.role == .user ? "编辑提问" : "编辑回复")
                    .toolbar {
                        ToolbarItem(placement:.cancellationAction){Button("取消"){editingBubble=nil}}
                        ToolbarItem(placement:.confirmationAction){Button("保存"){let target=bubble,content=editDraft;editingBubble=nil;Task{await session.edit(message:target,newContent:content)}}.disabled(editDraft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
                    }
            }
        }
        .alert("伴读失败",isPresented:Binding(get:{session.errorText != nil},set:{if !$0{session.errorText=nil}})){
            Button("重试上一条") { Task { await session.retryLast() } }
            Button("好",role:.cancel){}
        } message:{Text(session.errorText ?? "")}
        .alert("书库伴读",isPresented:Binding(get:{session.noticeText != nil},set:{if !$0{session.noticeText=nil}})){Button("好",role:.cancel){}}message:{Text(session.noticeText ?? "")}
    }
    @MainActor private func loadPersonas() async { personas=(try? await PersonaRepository.shared.personas()) ?? [] }
    @MainActor private func loadChatAppearance() async {
        let value=PersonaChatAppearance.decode(selectedPersona?.chatAppearanceJSON);chatAppearance=value
        if let id=value.backgroundImageId,let asset=try? await ImageAssetLibrary.shared.asset(id:id){chatBackgroundPath=asset.filePath}else{chatBackgroundPath=nil}
    }
}

private struct LibraryBubbleView: View {
    let bubble: CompanionBubble
    let appearance: PersonaChatAppearance
    @ObservedObject private var autonomy = CompanionAutonomySettingsStore.shared
    var body: some View {
        HStack {
            if bubble.role == .user { Spacer(minLength:50) }
            VStack(alignment:.leading,spacing:6) {
                if !bubble.reasoning.isEmpty { DisclosureGroup("思考过程") { Text(bubble.reasoning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
                PersonaChatBubbleSurface(role:bubble.role, appearance:appearance) {
                    Text(bubble.content.isEmpty && bubble.isStreaming ? "…" : bubble.content).textSelection(.enabled)
                }
                if bubble.role == .assistant && autonomy.showTokenUsage { CompanionTokenUsageInline(bubble: bubble) }
                if bubble.isStreaming { ProgressView().controlSize(.small) }
            }
            
            if bubble.role != .user { Spacer(minLength:50) }
        }
    }
}

private struct LibraryOrganizationPlanCard: View {
    let message: LibraryOrganizationMessage
    let action: (Bool) -> Void
    private var plan: LibraryOrganizationPlan { message.plan }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Label("书架整理方案",systemImage:"books.vertical.circle") .font(.headline)
                Spacer()
                Text(statusText).font(.caption.bold()).foregroundStyle(statusColor)
            }
            ForEach(plan.changes) { change in
                VStack(alignment:.leading,spacing:5) {
                    Text(change.title).font(.subheadline.bold())
                    if !change.addTags.isEmpty { Text("＋标签："+change.addTags.joined(separator:"、")).font(.caption) }
                    if !change.removeTags.isEmpty { Text("－标签："+change.removeTags.joined(separator:"、")).font(.caption) }
                    if let group=change.groupName { Text("分组："+(change.beforeGroupName.isEmpty ? "未分组":change.beforeGroupName)+" → "+group).font(.caption) }
                }
                .padding(9).frame(maxWidth:.infinity,alignment:.leading).background(.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
            }
            if plan.status == .pending {
                Text("方案只是预览；应用前会重新核对书名、原分组和原标签，书架已变化时会拒绝写入。")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("取消方案",role:.destructive){action(false)}
                    Spacer()
                    Button("应用方案"){action(true)}.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial,in:RoundedRectangle(cornerRadius:16))
    }
    private var statusText:String { switch plan.status { case .pending:"待确认";case .applied:"已应用";case .cancelled:"已取消" } }
    private var statusColor:Color { switch plan.status { case .pending:.orange;case .applied:.green;case .cancelled:.secondary } }
}

private struct CompanionTokenUsageInline: View {
    let bubble: CompanionBubble
    var body: some View {
        if let input=bubble.inputTokens,let output=bubble.outputTokens,input>0 || output>0 {
            let ms=max(1,bubble.generationTimeMs ?? 0),speed=Double(output)/(Double(ms)/1000.0)
            Text("输入 \(input) · 输出 \(output) · \(String(format:"%.1f",speed)) tok/s").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

private struct FocusBooksSheet: View {
    @State var selected:[Int64]
    let books:[Book]
    let done:([Int64])->Void
    var body:some View { NavigationStack { List(books){book in Button{if selected.contains(book.id){selected.removeAll{$0==book.id}}else if selected.count<4{selected.append(book.id)}}label:{HStack{VStack(alignment:.leading){Text(book.title);if !book.author.isEmpty{Text(book.author).font(.caption).foregroundStyle(.secondary)}};Spacer();if selected.contains(book.id){Image(systemName:"checkmark.circle.fill")}}}.buttonStyle(.plain)}.navigationTitle("重点讨论 · 最多 4 本").toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){done(selected)}}} } }
}

private struct PersonaPickerView: View {
    let personas:[PersonaRecord];let selection:Int64?;let choose:(Int64?)->Void
    var body:some View { List { Button{choose(nil)}label:{HStack{Text("默认伴读");Spacer();if selection==nil{Image(systemName:"checkmark")}}};ForEach(personas){p in Button{choose(p.id)}label:{HStack{PersonaAvatar(persona:p,size:36);VStack(alignment:.leading){Text(p.name);Text(p.subtitle).font(.caption).foregroundStyle(.secondary)};Spacer();if selection==p.id{Image(systemName:"checkmark")}}}}}.navigationTitle("选择角色") }
}

private struct ConversationPicker: View {
    @ObservedObject var session:LibraryCompanionSession
    @Environment(\.dismiss) private var dismiss
    var body:some View{List{Button("新建话题"){Task{_ = try? await session.create();dismiss()}};ForEach(session.conversations){c in Button{Task{try? await session.select(c.id);dismiss()}}label:{VStack(alignment:.leading){Text(c.title);Text(Date(timeIntervalSince1970:Double(c.updatedAt)/1000),style:.relative).font(.caption).foregroundStyle(.secondary)}}}}.navigationTitle("话题")}
}

struct PersonaLibraryView: View {
    @State private var personas:[PersonaRecord]=[]
    @State private var importing=false
    @State private var editing:PersonaRecord?
    @State private var creating=false
    @State private var errorText:String?
    var body:some View{
        List{
            ForEach(personas){p in Button{editing=p}label:{HStack(spacing:12){PersonaAvatar(persona:p,size:48);VStack(alignment:.leading){Text(p.name).font(.headline);Text(p.subtitle).font(.caption).foregroundStyle(.secondary);Text(p.personality).font(.caption).lineLimit(2).foregroundStyle(.secondary)};Spacer();if p.isBuiltIn{Text("内置").font(.caption2).padding(4).background(.thinMaterial,in:Capsule())}}}.buttonStyle(.plain)}.onDelete{set in Task{for i in set where personas.indices.contains(i){try? await PersonaRepository.shared.delete(id:personas[i].id)};await reload()}}
        }
        .toolbar{ToolbarItemGroup(placement:.topBarTrailing){Button{importing=true}label:{Image(systemName:"square.and.arrow.down")};Button{creating=true}label:{Image(systemName:"plus")}}}
        .sheet(isPresented:$importing){ExtensionFilePicker(extensions:["json","png"]){urls in importing=false;Task{do{if let u=urls.first{let access=u.startAccessingSecurityScopedResource();defer{if access{u.stopAccessingSecurityScopedResource()}};_ = try await PersonaRepository.shared.importCard(data:Data(contentsOf:u),filename:u.lastPathComponent)};await reload()}catch{errorText=error.localizedDescription}}}}
        .sheet(isPresented:$creating){NavigationStack{PersonaEditorView(persona:nil){creating=false;Task{await reload()}}}}
        .sheet(item:$editing){p in NavigationStack{PersonaEditorView(persona:p){editing=nil;Task{await reload()}}}}
        .task{await reload()}
        .alert("角色操作失败",isPresented:Binding(get:{errorText != nil},set:{if !$0{errorText=nil}})){Button("好",role:.cancel){}}message:{Text(errorText ?? "")}
    }
    @MainActor private func reload() async { do{personas=try await PersonaRepository.shared.personas()}catch{errorText=error.localizedDescription} }
}

private struct PersonaEditorView: View {
    let persona: PersonaRecord?
    let done: () -> Void
    @State private var draft: PersonaDraft
    @State private var appearance: PersonaChatAppearance
    @State private var loreName = ""
    @State private var loreContent = ""
    @State private var loreKeys = ""
    @State private var exampleUser = ""
    @State private var exampleAssistant = ""
    @State private var chatModels: [AIModelRecord] = []
    @State private var imageAssets: [ImageAssetRecord] = []
    @State private var fonts: [ReaderFontAsset] = []
    @State private var avatarImporting = false
    @State private var assistantColorHex: String
    @State private var userColorHex: String
    @State private var errorText: String?

    private let optionalTools: [(String,String,String)] = [
        ("add_annotation", "写角色批注", "允许角色在已读原文上创建可核验批注"),
        ("add_note", "写读书笔记", "允许角色按用户要求保存普通笔记"),
        ("save_plot_summary", "保存剧情梗概", "允许角色更新截至当前进度的剧情梗概"),
        ("recall_memory", "主动回忆长期记忆", "仍同时受角色记忆与全局长期记忆开关约束"),
        ("generate_image", "生成插图", "仍同时受“自主生图”总闸约束"),
        ("synthesize_speech", "显式合成语音", "仅在角色绑定音色时实际提供")
    ]

    init(persona: PersonaRecord?, done: @escaping () -> Void) {
        self.persona = persona; self.done = done
        let initial = persona.map { PersonaDraft(id:$0.id,name:$0.name,avatarPath:$0.avatarPath,subtitle:$0.subtitle,personality:$0.personality,speakingStyle:$0.speakingStyle,greeting:$0.greeting,exampleDialogs:$0.exampleDialogs,isRoleplay:$0.isRoleplay,enabledTools:$0.enabledTools,worldBook:$0.worldBook,worldBookEnabled:$0.worldBookEnabled,chatModelId:$0.chatModelId,userProfile:$0.userProfile,memoryEnabled:$0.memoryEnabled,chatAppearanceJSON:$0.chatAppearanceJSON,voiceId:$0.voiceId,voiceEmotion:$0.voiceEmotion) } ?? PersonaDraft(name: "")
        let app = PersonaChatAppearance.decode(initial.chatAppearanceJSON)
        _draft = State(initialValue: initial); _appearance = State(initialValue: app)
        _assistantColorHex = State(initialValue: Self.hex(app.assistantColorARGB))
        _userColorHex = State(initialValue: Self.hex(app.userColorARGB))
    }

    var body: some View {
        Form {
            identitySection
            examplesSection
            modelToolsSection
            memoryVoiceSection
            worldBookSection
            appearanceSection
        }
        .navigationTitle(persona == nil ? "新建角色" : "编辑角色")
        .toolbar {
            ToolbarItem(placement:.cancellationAction){Button("取消"){done()}}
            ToolbarItem(placement:.confirmationAction){Button("保存"){save()}}
        }
        .task { await loadOptions() }
        .sheet(isPresented:$avatarImporting){ExtensionFilePicker(extensions:["png","jpg","jpeg","webp"]){urls in avatarImporting=false;guard let url=urls.first else{return};Task{do{draft.avatarPath=try await PersonaRepository.shared.importAvatar(from:url)}catch{await MainActor.run{errorText=error.localizedDescription}}}}}
        .alert("保存失败",isPresented:Binding(get:{errorText != nil},set:{if !$0{errorText=nil}})){Button("好",role:.cancel){}}message:{Text(errorText ?? "")}
    }


    @ViewBuilder private var identitySection: some View {
        Section("身份与头像") {
            HStack(spacing: 14) {
                Group {
                    if let path=draft.avatarPath,let image=UIImage(contentsOfFile:path){Image(uiImage:image).resizable().scaledToFill()}
                    else{ZStack{Circle().fill(.secondary.opacity(0.14));Text(String(draft.name.prefix(1))).font(.title2.bold())}}
                }.frame(width:64,height:64).clipShape(Circle())
                VStack(alignment:.leading,spacing:8){Button("导入头像"){avatarImporting=true};if draft.avatarPath != nil{Button("移除头像",role:.destructive){draft.avatarPath=nil}}}
            }
            TextField("名称",text:$draft.name)
            TextField("副标题",text:$draft.subtitle)
            Toggle("角色扮演模式",isOn:$draft.isRoleplay)
            TextField("开场白",text:$draft.greeting,axis:.vertical).lineLimit(2...5)
            TextField("说话风格",text:$draft.speakingStyle,axis:.vertical).lineLimit(2...6)
            VStack(alignment:.leading){Text("角色设定").font(.caption).foregroundStyle(.secondary);TextEditor(text:$draft.personality).frame(minHeight:130)}
        }
    }

    @ViewBuilder private var examplesSection: some View {
        Section("示例对话") {
            ForEach(Array(draft.exampleDialogs.enumerated()),id:\.offset){index,item in
                VStack(alignment:.leading,spacing:4){Text("用户：\(item.user)").font(.caption);Text("角色：\(item.assistant)").font(.caption).foregroundStyle(.secondary);Button("删除",role:.destructive){draft.exampleDialogs.remove(at:index)}.font(.caption2)}
            }
            TextField("用户示例",text:$exampleUser,axis:.vertical)
            TextField("角色示例",text:$exampleAssistant,axis:.vertical)
            Button("添加示例"){let u=exampleUser.trimmingCharacters(in:.whitespacesAndNewlines),a=exampleAssistant.trimmingCharacters(in:.whitespacesAndNewlines);guard !u.isEmpty,!a.isEmpty else{return};draft.exampleDialogs.append(.init(user:String(u.prefix(2000)),assistant:String(a.prefix(4000))));exampleUser="";exampleAssistant=""}
        }
    }

    @ViewBuilder private var modelToolsSection: some View {
        Section("模型与能力") {
            Picker("专属对话模型",selection:Binding(get:{draft.chatModelId ?? 0},set:{draft.chatModelId=$0 == 0 ? nil:$0})){
                Text("跟随全局 CHAT 分配").tag(Int64(0));ForEach(chatModels){m in Text(m.modelName).tag(m.id)}
            }
            Text("查原文、目录、批注、笔记与联网搜索属于只读基础工具，不会被白名单关闭。下面只控制写入或付费媒体能力。")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(optionalTools,id:\.0){tool in
                Toggle(isOn:Binding(get:{draft.enabledTools.contains(tool.0)},set:{enabled in if enabled{if !draft.enabledTools.contains(tool.0){draft.enabledTools.append(tool.0)}}else{draft.enabledTools.removeAll{$0==tool.0}}})){
                    VStack(alignment:.leading){Text(tool.1);Text(tool.2).font(.caption).foregroundStyle(.secondary)}
                }
            }
        }
    }

    @ViewBuilder private var memoryVoiceSection: some View {
        Section("记忆与声音") {
            Toggle("长期记忆",isOn:$draft.memoryEnabled)
            if draft.memoryEnabled { TextField("用户画像（可手动修正）",text:$draft.userProfile,axis:.vertical).lineLimit(3...8) }
            TextField("TTS 音色 ID",text:$draft.voiceId)
            TextField("语音情绪 / 风格",text:$draft.voiceEmotion)
        }
    }

    @ViewBuilder private var worldBookSection: some View {
        Section("世界书 / 设定集") {
            Toggle("启用世界书",isOn:$draft.worldBookEnabled)
            ForEach(draft.worldBook.indices,id:\.self){i in
                VStack(alignment:.leading,spacing:6){
                    HStack{Toggle("",isOn:Binding(get:{draft.worldBook[i].enabled},set:{draft.worldBook[i].enabled=$0})).labelsHidden();Text(draft.worldBook[i].name.ifBlank("未命名条目")).font(.headline);Spacer();Picker("",selection:Binding(get:{draft.worldBook[i].constant},set:{draft.worldBook[i].constant=$0})){Text("关键词触发").tag(false);Text("常驻").tag(true)}.labelsHidden().pickerStyle(.menu)}
                    Text(draft.worldBook[i].content).font(.caption).lineLimit(4)
                    if !draft.worldBook[i].keys.isEmpty { Text("关键词："+draft.worldBook[i].keys.joined(separator:"、")).font(.caption2).foregroundStyle(.secondary) }
                    Button("删除条目",role:.destructive){draft.worldBook.remove(at:i)}.font(.caption2)
                }
            }
            TextField("条目名称",text:$loreName);TextField("触发词（逗号分隔；留空=常驻）",text:$loreKeys);TextField("内容",text:$loreContent,axis:.vertical).lineLimit(3...8)
            Button("添加世界书条目"){let c=loreContent.trimmingCharacters(in:.whitespacesAndNewlines);guard !c.isEmpty else{return};let keys=loreKeys.split(whereSeparator:{",，;；".contains($0)}).map{String($0).trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty};draft.worldBook.append(.init(name:String(loreName.prefix(80)),content:String(c.prefix(12000)),enabled:true,constant:keys.isEmpty,keys:keys));loreName="";loreKeys="";loreContent=""}
        }
    }

    @ViewBuilder private var appearanceSection: some View {
        Section("聊天外观") {
            Picker("背景图",selection:Binding(get:{appearance.backgroundImageId ?? ""},set:{appearance.backgroundImageId=$0.isEmpty ? nil:$0})){
                Text("跟随阅读主题 / 无独立背景").tag("");ForEach(imageAssets){Text($0.name).tag($0.id)}
            }
            if appearance.backgroundImageId != nil { Slider(value:$appearance.backgroundDim,in:0...1){Text("背景蒙版")} minimumValueLabel:{Text("透")} maximumValueLabel:{Text("暗")};Text("背景蒙版 \(Int(appearance.backgroundDim*100))%").font(.caption).foregroundStyle(.secondary) }
            Picker("聊天字体",selection:Binding(get:{appearance.fontId ?? ""},set:{appearance.fontId=$0.isEmpty ? nil:$0})){
                Text("跟随 App 字体").tag("");ForEach(fonts){Text($0.displayName).tag($0.postScriptName)}
            }
            Slider(value:$appearance.fontScale,in:0.8...1.6,step:0.05){Text("字体比例")};Text("字体比例 \(appearance.fontScale,specifier:"%.2f")×").font(.caption).foregroundStyle(.secondary)
            Picker("气泡样式",selection:Binding(get:{appearance.shape},set:{appearance.bubbleShape=$0.rawValue})){ForEach(ChatBubbleShape.allCases){Text($0.label).tag($0)}}
            TextField("角色气泡颜色（#RRGGBB / #AARRGGBB，空=跟随主题）",text:$assistantColorHex)
            TextField("用户气泡颜色（#RRGGBB / #AARRGGBB，空=强调色）",text:$userColorHex)
        }
    }
    @MainActor private func loadOptions() async {
        chatModels=((try? await AIProviderRepository.shared.models()) ?? []).filter{$0.type == .chat}
        imageAssets=(try? await ImageAssetLibrary.shared.list()) ?? []
        fonts=ReaderFontLibrary.assets()
    }
    private func save() {
        appearance.assistantColorARGB=Self.argb(assistantColorHex);appearance.userColorARGB=Self.argb(userColorHex);draft.chatAppearanceJSON=appearance.sanitized().encoded()
        Task{do{_ = try await PersonaRepository.shared.save(draft);await MainActor.run{done()}}catch{await MainActor.run{errorText=error.localizedDescription}}}
    }
    private static func hex(_ value:Int64?)->String { guard let value else{return ""};let v=UInt32(truncatingIfNeeded:value);return String(format:v>>24 == 0xFF ? "#%06X":"#%08X",v>>24 == 0xFF ? v&0xFFFFFF:v) }
    private static func argb(_ raw:String)->Int64? { let s=raw.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"#",with:"");guard [6,8].contains(s.count),let value=UInt32(s,radix:16) else{return nil};return Int64(s.count==6 ? (0xFF000000|value):value) }
}

private extension String { func ifBlank(_ fallback:String)->String { trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? fallback:self } }

private struct PersonaAvatar:View{let persona:PersonaRecord;let size:CGFloat;var body:some View{Group{if let path=persona.avatarPath,let image=UIImage(contentsOfFile:path){Image(uiImage:image).resizable().scaledToFill()}else{ZStack{Circle().fill(.secondary.opacity(0.15));Text(String(persona.name.prefix(1))).font(.headline)}}}.frame(width:size,height:size).clipShape(Circle())}}
