import AVFoundation
import SwiftUI

struct AIServiceSettingsView: View {
    @State private var providers:[AIProviderRecord]=[]
    @State private var models:[AIModelRecord]=[]
    @State private var assignments:[ModelRole:Int64?]=[:]
    @State private var showProvider=false
    @State private var showModelFor:Int64?
    @State private var errorText:String?
    var body:some View{List{
        Section("服务商"){
            ForEach(providers){p in NavigationLink{ProviderDetailView(provider:p,onChanged:{Task{await reload()}})}label:{VStack(alignment:.leading){Text(p.name);Text("\(p.adapter.rawValue) · \(p.apiFormat.rawValue) · \(p.baseURL)").font(.caption).foregroundStyle(.secondary)}}}
            Button("添加服务商"){showProvider=true}
        }
        Section("模型角色分配"){
            ForEach(ModelRole.allCases,id:\.self){role in Picker(roleLabel(role),selection:Binding(get:{assignments[role] ?? nil},set:{value in assignments[role]=value;Task{do{try await AIProviderRepository.shared.assign(role:role,modelId:value ?? nil)}catch{errorText=error.localizedDescription}}})){Text("未分配").tag(Int64?.none);ForEach(compatible(role)){m in Text(modelLabel(m)).tag(Optional(m.id))}}}
        }
    }.navigationTitle("AI 服务").toolbar{ToolbarItem(placement:.topBarTrailing){Button{showProvider=true}label:{Image(systemName:"plus")}}}.sheet(isPresented:$showProvider){ProviderEditorView{draft in do{_ = try await AIProviderRepository.shared.save(draft);await reload();return nil}catch{return error.localizedDescription}}}.task{await reload()}.alert("配置失败",isPresented:Binding(get:{errorText != nil},set:{if !$0{errorText=nil}})){Button("好",role:.cancel){}}message:{Text(errorText ?? "")}}
    @MainActor private func reload()async{do{providers=try await AIProviderRepository.shared.providers();models=try await AIProviderRepository.shared.models();for r in ModelRole.allCases{assignments[r]=try await AIProviderRepository.shared.assignment(r)}}catch{errorText=error.localizedDescription}}
    private func compatible(_ role:ModelRole)->[AIModelRecord]{let type:AiModelType=switch role{case .chat,.translation,.cheap,.suggestion,.proactiveAnnotation:.chat;case .embedding:.embedding;case .rerank:.rerank;case .tts:.tts;case .image:.image};return models.filter{$0.type==type}}
    private func modelLabel(_ m:AIModelRecord)->String{let p=providers.first{$0.id==m.providerId}?.name ?? "Provider";return "\(p) · \(m.modelName)"}
    private func roleLabel(_ r:ModelRole)->String{switch r{case .chat:"主对话";case .translation:"阅读翻译";case .cheap:"批量任务";case .suggestion:"建议回复";case .proactiveAnnotation:"主动段评";case .embedding:"Embedding";case .rerank:"Rerank";case .tts:"TTS";case .image:"生图"}}
}

private struct ProviderEditorView:View{
    @Environment(\.dismiss) var dismiss
    @State var name="";@State var base="https://api.openai.com/v1";@State var key="";@State var adapter:AiProviderAdapter = .custom;@State var dialect:ApiDialect = .openAI;@State var extra="{}";@State var error:String?
    let save:(AIProviderDraft) async->String?
    var body:some View{NavigationStack{Form{TextField("名称",text:$name);TextField("Base URL",text:$base).textInputAutocapitalization(.never).keyboardType(.URL);SecureField("API Key",text:$key);Picker("适配",selection:$adapter){ForEach(AiProviderAdapter.allCases,id:\.self){Text($0.rawValue).tag($0)}};Picker("对话协议",selection:$dialect){ForEach(ApiDialect.allCases,id:\.self){Text($0.rawValue).tag($0)}};Section("高级 extraJson"){TextEditor(text:$extra).font(.system(.caption,design:.monospaced)).frame(minHeight:100)}}.navigationTitle("添加服务商").toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("保存"){Task{if let e=await save(.init(name:name,baseURL:base,apiFormat:dialect,adapter:adapter,extraJSON:extra,apiKey:key)){error=e}else{dismiss()}}}}}.alert("保存失败",isPresented:Binding(get:{error != nil},set:{if !$0{error=nil}})){Button("好",role:.cancel){}}message:{Text(error ?? "")}}}
}

private struct ProviderDetailView:View{
    let provider:AIProviderRecord;let onChanged:()->Void
    @State private var models:[AIModelRecord]=[];@State private var showModel=false;@State private var error:String?
    var body:some View{List{Section("服务商"){LabeledContent("名称",value:provider.name);LabeledContent("Base URL",value:provider.baseURL);LabeledContent("协议",value:provider.apiFormat.rawValue)};Section("模型"){ForEach(models){m in VStack(alignment:.leading){Text(m.modelName);Text("\(m.type.rawValue) · \(m.chatApiFormat.isEmpty ? "默认协议":m.chatApiFormat) \(m.endpointPath)").font(.caption).foregroundStyle(.secondary)}}.onDelete{set in Task{for i in set where models.indices.contains(i){try? await AIProviderRepository.shared.removeModel(models[i].id)};await reload()}};Button("添加模型"){showModel=true}}}.navigationTitle(provider.name).toolbar{ToolbarItem(placement:.topBarTrailing){Button{showModel=true}label:{Image(systemName:"plus")}}}.sheet(isPresented:$showModel){ModelEditorView{draft in do{_ = try await AIProviderRepository.shared.saveModel(providerId:provider.id,draft:draft);await reload();onChanged();return nil}catch{return error.localizedDescription}}}.task{await reload()}.alert("操作失败",isPresented:Binding(get:{error != nil},set:{if !$0{error=nil}})){Button("好",role:.cancel){}}message:{Text(error ?? "")}}
    @MainActor private func reload()async{do{models=try await AIProviderRepository.shared.models(providerId:provider.id)}catch{self.error=error.localizedDescription}}
}

private struct ModelEditorView:View{
    @Environment(\.dismiss) var dismiss
    @State var name="";@State var type:AiModelType = .chat;@State var dialect:ApiDialect = .openAI;@State var endpoint="";@State var extra="{}";@State var error:String?
    let save:(AIModelDraft) async->String?
    var body:some View{NavigationStack{Form{TextField("模型名",text:$name);Picker("能力",selection:$type){ForEach(AiModelType.allCases,id:\.self){Text($0.rawValue).tag($0)}};if type == .chat{Picker("协议",selection:$dialect){ForEach(ApiDialect.allCases,id:\.self){Text($0.rawValue).tag($0)}}};TextField("自定义端点（可空）",text:$endpoint).textInputAutocapitalization(.never);TextEditor(text:$extra).font(.system(.caption,design:.monospaced)).frame(minHeight:100)}.navigationTitle("添加模型").toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("保存"){Task{let d=AIModelDraft(modelName:name,type:type,chatApiFormat:type == .chat ? dialect.rawValue:"",endpointPath:endpoint,extraJSON:extra);if let e=await save(d){error=e}else{dismiss()}}}}}.alert("保存失败",isPresented:Binding(get:{error != nil},set:{if !$0{error=nil}})){Button("好",role:.cancel){}}message:{Text(error ?? "")}}}
}

struct DictionarySettingsView:View{
    @State private var dictionaries:[LocalDictionary]=[];@State private var importingMDX=false;@State private var importingMDD=false;@State private var resourceTarget:String?;@State private var errorText:String?
    var body:some View{List{ForEach(dictionaries){d in HStack{VStack(alignment:.leading){Text(d.title);Text("\(d.resourceCount) 个 MDD 资源包").font(.caption).foregroundStyle(.secondary)};Spacer();Toggle("",isOn:Binding(get:{d.enabled},set:{v in Task{try? await LocalDictionaryRepository.shared.setEnabled(d.id,enabled:v);await reload()}}));Button{resourceTarget=d.id;importingMDD=true}label:{Image(systemName:"shippingbox")}}}.onDelete{set in Task{for i in set where dictionaries.indices.contains(i){try? await LocalDictionaryRepository.shared.delete(dictionaries[i].id)};await reload()}};Button("导入 MDX"){importingMDX=true}}.navigationTitle("本地词典").sheet(isPresented:$importingMDX){ExtensionFilePicker(extensions:["mdx"]){urls in importingMDX=false;Task{do{if let u=urls.first{_ = try await LocalDictionaryRepository.shared.importMdx(from:u)};await reload()}catch{errorText=error.localizedDescription}}}}.sheet(isPresented:$importingMDD){ExtensionFilePicker(extensions:["mdd"],allowsMultiple:true){urls in importingMDD=false;Task{do{if let id=resourceTarget{_ = try await LocalDictionaryRepository.shared.importResources(dictionaryId:id,urls:urls)};await reload()}catch{errorText=error.localizedDescription}}}}.task{await reload()}.alert("词典操作失败",isPresented:Binding(get:{errorText != nil},set:{if !$0{errorText=nil}})){Button("好",role:.cancel){}}message:{Text(errorText ?? "")}}
    @MainActor private func reload()async{do{dictionaries=try await LocalDictionaryRepository.shared.list()}catch{errorText=error.localizedDescription}}
}

struct SpeechSettingsView:View{
    @ObservedObject private var store=TTSSettingsStore.shared
    @State private var previewText="欢迎使用墨知语音朗读。";@State private var previewPlayer:AVAudioPlayer?;@State private var errorText:String?
    private var voices:[AVSpeechSynthesisVoice]{AVSpeechSynthesisVoice.speechVoices().sorted{$0.name<$1.name}}
    var body:some View{Form{Picker("引擎",selection:$store.settings.engineMode){Text("系统 TTS").tag(TTSEngineMode.system);Text("云 TTS").tag(TTSEngineMode.ai)};if store.settings.engineMode == .system{Picker("系统音色",selection:$store.settings.systemVoiceIdentifier){Text("系统默认").tag("");ForEach(voices,id:\.identifier){Text("\($0.name) · \($0.language)").tag($0.identifier)}};LabeledContent("语速"){Slider(value:$store.settings.systemRate,in:0.5...2)}}else{Picker("服务",selection:Binding(get:{store.settings.aiProvider},set:{store.switchProvider($0)})){ForEach(TTSAPIProvider.allCases,id:\.self){Text($0.rawValue).tag($0)}};TextField("Base URL",text:$store.settings.aiBaseURL).textInputAutocapitalization(.never);TextField("模型",text:$store.settings.aiModel);TextField("音色 ID",text:$store.settings.aiVoiceId);SecureField("API Key",text:$store.apiKey);LabeledContent("语速"){Slider(value:$store.settings.aiSpeed,in:0.5...2)};TextField("试听文本",text:$previewText);Button("试听云 TTS"){Task{do{let s=try await CloudSpeechService.shared.synthesize(text:previewText);let p=try AVAudioPlayer(data:s.data);previewPlayer=p;p.play()}catch{errorText=error.localizedDescription}}}};Section("合成策略"){Picker("粒度",selection:$store.settings.synthesisGranularity){Text("逐句").tag(TTSSynthesisGranularity.sentence);Text("段落").tag(TTSSynthesisGranularity.paragraph);Text("章节").tag(TTSSynthesisGranularity.chapter)};Stepper("单次最多 \(store.settings.maxSynthesisChars) 字",value:$store.settings.maxSynthesisChars,in:80...2000,step:20);Toggle("允许与其他音频混音",isOn:$store.settings.allowAudioMixing)}}.navigationTitle("语音朗读").alert("TTS 失败",isPresented:Binding(get:{errorText != nil},set:{if !$0{errorText=nil}})){Button("好",role:.cancel){}}message:{Text(errorText ?? "")}}
}

struct ProactiveSettingsView: View {
    @ObservedObject private var store = ProactiveAnnotationSettingsStore.shared
    @State private var personas: [PersonaRecord] = []

    var body: some View {
        Form {
            Toggle("启用随读段评", isOn: $store.enabled)

            Section("伴读角色") {
                if personas.isEmpty {
                    Text("没有可用角色；未指定时会使用默认伴读角色。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(personas) { persona in
                        Toggle(isOn: Binding(
                            get: { store.personaIds.contains(persona.id) },
                            set: { enabled in
                                var ids = Set(store.personaIds)
                                if enabled { ids.insert(persona.id) } else { ids.remove(persona.id) }
                                store.personaIds = ids.sorted()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(persona.name)
                                if !persona.subtitle.isEmpty { Text(persona.subtitle).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Text("不勾选任何角色时使用默认角色；选择多个角色时会公平分摊剩余每日额度。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("触发") {
                Picker("生成时机", selection: $store.limits.timing) {
                    ForEach(ProactiveAnnotationTiming.allCases, id: \.self) { timing in Text(timing.label).tag(timing) }
                }
                if store.limits.timing == .onChapterEntry {
                    Stepper("提前生成到后面 \(store.limits.aheadChapters) 章", value: $store.limits.aheadChapters, in: 0...5)
                    Text("预生成会读取你明确设置的当前章及后续章，但未来章节的段评会按 sourceScope 隐藏，直到阅读进度抵达。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("数量与频控") {
                Stepper("每章至少 \(store.limits.minPerChapter) 条", value: $store.limits.minPerChapter, in: 0...10)
                Picker("每章最多", selection: $store.limits.maxPerChapter) {
                    ForEach(Array(1...10), id: \.self) { Text("\($0) 条").tag($0) }
                    Text("不限制").tag(ProactiveAnnotationLimits.unlimited)
                }
                Picker("每日最多", selection: $store.limits.dailyMax) {
                    ForEach(Array(1...50), id: \.self) { Text("\($0) 条").tag($0) }
                    Text("不限制").tag(ProactiveAnnotationLimits.unlimited)
                }
                Stepper("每日语音最多 \(limitLabel(store.limits.dailyVoiceMax))", value: $store.limits.dailyVoiceMax, in: -1...50)
                Stepper("每日插图最多 \(limitLabel(store.limits.dailyImageMax))", value: $store.limits.dailyImageMax, in: -1...50)
                Stepper("前文上下文 \(store.limits.contextBudgetChars) 字", value: $store.limits.contextBudgetChars, in: 4_000...64_000, step: 4_000)
            }

            Section("媒体与提醒") {
                Toggle("允许角色语音段评", isOn: $store.voiceEnabled)
                Toggle("允许段评生成插图", isOn: $store.imagesEnabled)
                Picker("互动提醒", selection: $store.noticeMode) {
                    ForEach(ProactiveAnnotationNoticeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }

            Section {
                Text("主动段评模型未单独分配时回落到 CHEAP，再回落主对话模型。正文 revision、段落完成水位和失败轮次均会持久化；切书或关闭功能会取消当前调度，但已完成段落不会重复付费。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("随读段评")
        .task { personas = (try? await PersonaRepository.shared.personas()) ?? [] }
    }

    private func limitLabel(_ value: Int) -> String { value == ProactiveAnnotationLimits.unlimited ? "不限制" : "\(value) 条" }
}


struct BackupSettingsView:View{
    @ObservedObject private var store=BackupSettingsStore.shared
    @State private var remotes:[RemoteBackup]=[];@State private var localBackup:URL?;@State private var restoring=false;@State private var progress="";@State private var errorText:String?
    var body:some View{Form{Section("WebDAV"){TextField("https://…",text:$store.settings.webDAVURL).textInputAutocapitalization(.never).keyboardType(.URL);TextField("用户名",text:$store.settings.username);SecureField("密码 / 应用专用密码",text:$store.password);TextField("远端目录",text:$store.settings.remoteDirectory);Toggle("每日轻量自动备份",isOn:Binding(get:{store.settings.autoBackup},set:{v in store.settings.autoBackup=v;BackupBackgroundScheduler.update(enabled:v)}));Button("测试连接"){Task{await test()}}};Section("自动备份状态"){if let t=store.settings.lastBackgroundScheduleAt{LabeledContent("最近提交调度",value:format(t))};if let t=store.settings.lastAutoBackupAttemptAt{LabeledContent("最近自动尝试",value:format(t))};if let t=store.settings.lastAutoBackupAt{LabeledContent("最近自动成功",value:format(t))};if let e=store.settings.lastAutoBackupError,!e.isEmpty{Text(e).font(.caption).foregroundStyle(.red)};Text("iOS 由系统决定后台任务实际执行时刻；这里显示的是最近一次提交与执行结果。") .font(.footnote).foregroundStyle(.secondary)};Section("备份"){Button("立即完整备份到 WebDAV"){Task{await backup(.full)}};Button("立即轻量备份到 WebDAV"){Task{await backup(.lightweight)}};Button("生成本地完整备份"){Task{do{localBackup=try await BackupArchiveManager.shared.create(mode:.full)}catch{errorText=error.localizedDescription}}};if let localBackup{ShareLink(item:localBackup){Label("分享 \(localBackup.lastPathComponent)",systemImage:"square.and.arrow.up")}};Button("从本地备份恢复"){restoring=true}};if !progress.isEmpty{Section{Text(progress)}};if !remotes.isEmpty{Section("远端备份"){ForEach(remotes){r in HStack{VStack(alignment:.leading){Text(r.name);Text(ByteCountFormatter.string(fromByteCount:r.size,countStyle:.file)).font(.caption).foregroundStyle(.secondary)};Spacer();Button("恢复"){Task{await restoreRemote(r)}}}}}}}.navigationTitle("备份与恢复").sheet(isPresented:$restoring){ExtensionFilePicker(extensions:["zip"]){urls in restoring=false;Task{do{if let u=urls.first{_ = try await BackupArchiveManager.shared.stageRestore(u);errorText="恢复数据已准备好，请完全退出并重新打开应用"}}catch{errorText=error.localizedDescription}}}}.task{store.reload();await refreshRemote()}.alert("提示",isPresented:Binding(get:{errorText != nil},set:{if !$0{errorText=nil}})){Button("好",role:.cancel){}}message:{Text(errorText ?? "")}}
    @MainActor private func test()async{do{let c=try store.credentials();try await BackupRepository.shared.test(credentials:c);progress="连接成功";remotes=try await BackupRepository.shared.list(credentials:c)}catch{errorText=error.localizedDescription}}
    @MainActor private func refreshRemote()async{guard let c=try? store.credentials() else{return};remotes=(try? await BackupRepository.shared.list(credentials:c)) ?? []}
    @MainActor private func backup(_ mode:BackupMode)async{do{let c=try store.credentials();_ = try await BackupRepository.shared.backupToWebDAV(credentials:c,mode:mode){p in Task{@MainActor in progress=formatProgress(p)}};store.markBackup();await refreshRemote()}catch{errorText=error.localizedDescription}}
    @MainActor private func restoreRemote(_ r:RemoteBackup)async{do{let c=try store.credentials();_ = try await BackupRepository.shared.stageRemoteRestore(credentials:c,name:r.name){p in Task{@MainActor in progress=formatProgress(p)}};errorText="恢复数据已准备好，请完全退出并重新打开应用"}catch{errorText=error.localizedDescription}}
    private func formatProgress(_ p:BackupProgress)->String{if p.totalBytes>0{return "\(p.phase) \(p.percent)% · \(ByteCountFormatter.string(fromByteCount:p.completedBytes,countStyle:.file)) / \(ByteCountFormatter.string(fromByteCount:p.totalBytes,countStyle:.file))"};return "\(p.phase) \(p.percent)%"}
    private func format(_ ms:Int64)->String{Date(timeIntervalSince1970:Double(ms)/1000).formatted(date:.abbreviated,time:.shortened)}
}

struct LANTransferSettingsView: View {
    @StateObject private var server = LANTransferServer.shared
    var body: some View {
        Form {
            Section("局域网传书") {
                if server.running {
                    LabeledContent("访问地址", value: server.address)
                        .textSelection(.enabled)
                    ShareLink(item: server.address) { Label("分享地址", systemImage: "square.and.arrow.up") }
                    Button("停止传书服务", role: .destructive) { server.stop() }
                } else {
                    Button("启动局域网传书") { server.start() }
                }
                if !server.status.isEmpty { Text(server.status).foregroundStyle(.secondary) }
                if server.importedCount > 0 { LabeledContent("本次已导入", value: "\(server.importedCount) 本") }
            }
            Section {
                Text("让 iPhone/iPad 与电脑处于同一 Wi‑Fi，在电脑浏览器打开上面的地址即可上传 TXT / EPUB。文件上传后会立即经过与系统文件选择器相同的正式导入、分章和 text.mz 写入流程。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("局域网传书")
        .onDisappear { /* Android 版允许后台保持服务；iOS 同样不因离开设置页主动停止。 */ }
    }
}

struct ReviewShareTemplateSettingsView: View {
    @ObservedObject private var store = ReviewShareTemplateStore.shared
    @State private var editing: ReviewShareTemplate?
    var body: some View {
        List {
            ForEach(store.templates) { template in
                Button { editing = template } label: {
                    HStack {
                        RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: UIColor(argbValue: template.backgroundARGB))).frame(width: 34, height: 34)
                        VStack(alignment: .leading) { Text(template.name); if !template.css.isEmpty { Text(template.css).font(.caption2).foregroundStyle(.secondary).lineLimit(1) } }
                    }
                }.buttonStyle(.plain)
            }.onDelete { set in for i in set where store.templates.indices.contains(i) { store.delete(store.templates[i].id) } }
            Button("新建分享模板") { editing = .init(id: UUID().uuidString, name: "新模板") }
        }
        .navigationTitle("回顾分享模板")
        .sheet(item: $editing) { value in ReviewShareTemplateEditor(template: value) { store.upsert($0) } }
    }
}

private struct ReviewShareTemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var template: ReviewShareTemplate
    var onSave: (ReviewShareTemplate) -> Void
    @State private var errorText: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("模板名称", text: $template.name)
                ColorPicker("背景色", selection: colorBinding(\.backgroundARGB), supportsOpacity: false)
                ColorPicker("文字色", selection: colorBinding(\.textARGB), supportsOpacity: false)
                ColorPicker("强调色", selection: colorBinding(\.accentARGB), supportsOpacity: false)
                TextField("字体 PostScript 名称（可空）", text: $template.fontChoice)
                Section("CSS") {
                    TextEditor(text: $template.css).font(.system(.caption, design: .monospaced)).frame(minHeight: 140)
                    Text("支持 font-size、line-height、letter-spacing、padding、margin-top/bottom、border-radius、font-style、text-decoration。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("分享模板")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .alert("模板无效", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorText ?? "") }
        }
    }
    private func save() {
        let name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorText = "模板名称不能为空"; return }
        let parsed = ReviewTemplateStyle.parse(template.css)
        guard parsed.errors.isEmpty else { errorText = parsed.errors.joined(separator: "\n"); return }
        template.name = name; onSave(template); dismiss()
    }
    private func colorBinding(_ keyPath: WritableKeyPath<ReviewShareTemplate, UInt32>) -> Binding<Color> {
        Binding(get: { Color(uiColor: UIColor(argbValue: template[keyPath: keyPath])) }, set: { template[keyPath: keyPath] = $0.argbValue })
    }
}

private extension UIColor {
    convenience init(argbValue: UInt32) { self.init(red: CGFloat((argbValue >> 16) & 255)/255, green: CGFloat((argbValue >> 8) & 255)/255, blue: CGFloat(argbValue & 255)/255, alpha: CGFloat((argbValue >> 24) & 255)/255) }
    var argbValue: UInt32 {
        var r: CGFloat=0,g:CGFloat=0,b:CGFloat=0,a:CGFloat=0; getRed(&r, green:&g, blue:&b, alpha:&a)
        return (UInt32((a*255).rounded())<<24)|(UInt32((r*255).rounded())<<16)|(UInt32((g*255).rounded())<<8)|UInt32((b*255).rounded())
    }
}
private extension Color { var argbValue: UInt32 { UIColor(self).argbValue } }
