import AVFoundation
import SwiftUI

struct AudiobookStudioView: View {
    let book: Book
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let chapters: [Chapter]
    let currentChapterIndex: Int
    let currentChapterText: String

    @ObservedObject private var ttsStore = TTSSettingsStore.shared
    @StateObject private var playback = AudiobookPlaybackSession()
    @State private var roles: [AudiobookRole] = []
    @State private var segments: [AudiobookSegment] = []
    @State private var chapterState: AudiobookChapterState?
    @State private var cloudVoices: [TTSVoiceRecord] = []
    @State private var editingRole: AudiobookRole?
    @State private var policy: AudiobookEnginePolicy = .narratorSystemCharactersAI
    @State private var firstChapter = 0
    @State private var lastChapter = 0
    @State private var pricePerTenThousand = 0.0
    @State private var estimate = AudiobookCostEstimate(totalChars: 0, segmentCount: 0, aiSegmentCount: 0, systemSegmentCount: 0, estimatedCost: 0)
    @State private var productionProgress: AudiobookProductionProgress?
    @State private var productionTask: Task<Void, Never>?
    @State private var busy = false
    @State private var errorText: String?

    private var currentTitle: String { chapters.indices.contains(currentChapterIndex) ? chapters[currentChapterIndex].title : "第 \(currentChapterIndex + 1) 章" }
    private var maxChapter: Int { min(max(0, book.maxReachedChapterIndex), max(0, chapters.count - 1)) }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            castingSection
                            productionSection
                        }
                        .padding(22)
                    }
                    .frame(minWidth: 360, idealWidth: 430, maxWidth: 520)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            scriptSection
                            playbackSection
                        }
                        .padding(22)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        castingSection
                        scriptSection
                        productionSection
                        playbackSection
                    }.padding()
                }
            }
        }
        .task { await loadAll() }
        .sheet(item: $editingRole) { role in RoleEditorView(role: role, cloudVoices: cloudVoices) { updated in Task { await saveRole(updated) } } }
        .alert("有声书", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorText ?? "") }
        .onDisappear { productionTask?.cancel(); playback.stop() }
    }

    private var castingSection: some View {
        GroupBox("角色与音色") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("引擎策略", selection: $policy) { ForEach(AudiobookEnginePolicy.allCases, id: \.self) { Text($0.label).tag($0) } }
                    Button("应用") { Task { await applyPolicy() } }.disabled(policy == .custom)
                }
                HStack {
                    Button(roles.isEmpty ? "提取角色" : "更新角色") { Task { await extractRoles() } }.disabled(busy)
                    Button("自动分配音色") { Task { await autoAssignVoices() } }.disabled(roles.isEmpty)
                    Button("刷新 Gemini 音色") { Task { await refreshGeminiVoices() } }.disabled(ttsStore.settings.aiProvider != .gemini)
                }
                ForEach(roles) { role in
                    HStack(alignment: .top) {
                        Circle().fill(Color(hex: role.color) ?? .secondary).frame(width: 10, height: 10).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(role.name).font(.headline)
                            Text("\(role.kind == .narrator ? "旁白" : "角色") · \(role.engine == .system ? "系统 TTS" : "AI TTS") · \(voiceLabel(role))")
                                .font(.caption).foregroundStyle(.secondary)
                            if !role.aliases.isEmpty { Text("别名：\(role.aliases.joined(separator: "、"))").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer(); Button("编辑") { editingRole = role }
                    }
                }
                if roles.isEmpty { Text("先提取旁白与角色，再分配系统或云端音色。已确认过的人工音色不会因重新抽取人物而被覆盖。") .font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var scriptSection: some View {
        GroupBox("当前章剧本 · \(currentTitle)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(segments.isEmpty ? "生成剧本" : "重新精排") { Task { await generateScript() } }.disabled(busy || roles.isEmpty)
                    if chapterState?.status == .scripted || chapterState?.status == .stale {
                        Button("确认剧本") { Task { await confirmScript() } }.buttonStyle(.borderedProminent)
                    }
                    Spacer(); Text(chapterStateLabel).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(segments) { segment in
                    let text = segmentText(segment)
                    HStack(alignment: .top, spacing: 10) {
                        Picker("角色", selection: Binding(
                            get: { segment.roleId ?? roles.first?.id ?? 0 },
                            set: { value in Task { await updateSegment(segment, roleId: value) } }
                        )) { ForEach(roles) { Text($0.name).tag($0.id) } }
                        .labelsHidden().frame(maxWidth: 130)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(text).lineLimit(5)
                            HStack {
                                Text(segment.emotion ?? "中性")
                                if let instruction = segment.instruction, !instruction.isEmpty { Text("· \(instruction)") }
                                if let path = segment.audioPath { Text(path.isEmpty ? "· 无需音频" : "· 已缓存") }
                            }.font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if segments.isEmpty { Text("本地规则先切对白和旁白，AI 只负责歧义角色归属、情绪与表演提示；所有 UTF-16 坐标由本机确定。") .font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var productionSection: some View {
        GroupBox("批量生产") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Stepper("起：\(firstChapter + 1)", value: $firstChapter, in: 0...maxChapter)
                    Stepper("止：\(lastChapter + 1)", value: $lastChapter, in: firstChapter...maxChapter)
                }
                HStack {
                    Text("AI TTS 每万字价格")
                    TextField("0", value: $pricePerTenThousand, format: .number).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(width: 100)
                    Button("估算") { Task { await updateEstimate() } }
                }
                LabeledContent("片段", value: "\(estimate.segmentCount)（AI \(estimate.aiSegmentCount) / 系统 \(estimate.systemSegmentCount)）")
                LabeledContent("AI 字符费用估算", value: estimate.estimatedCost.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD")))
                HStack {
                    if productionTask == nil {
                        Button("生产已确认章节") { startProduction() }.buttonStyle(.borderedProminent)
                    } else {
                        Button("停止生产", role: .destructive) { productionTask?.cancel(); productionTask = nil }
                    }
                }
                if let p = productionProgress {
                    ProgressView(value: Double(p.completedSegments), total: Double(max(1, p.totalSegments)))
                    Text("\(p.chapterTitle) · AI 音频 \(p.completedSegments)/\(p.totalSegments)").font(.caption).foregroundStyle(.secondary)
                }
                Text("系统 TTS 片段不预生成音频；AI TTS 片段缓存到本机。正文、角色引擎或音色变化会让相关缓存失效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var playbackSection: some View {
        GroupBox("试听 / 播放当前章") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button { playback.previous() } label: { Image(systemName: "backward.end.fill") }
                    Button {
                        if playback.playing { playback.pause() } else if playback.currentIndex > 0 { playback.resume() } else { playback.play() }
                    } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill").font(.title2) }
                    Button { playback.next() } label: { Image(systemName: "forward.end.fill") }
                    Button("停止") { playback.stop() }
                    Spacer(); Text(playback.progressLabel).monospacedDigit()
                }
                Text("当前：\(playback.currentRoleName)").font(.caption).foregroundStyle(.secondary)
                if let error = playback.errorText { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    private var chapterStateLabel: String {
        guard let state = chapterState?.status else { return "未生成" }
        switch state { case .none:return"未生成";case .scripted:return"待确认";case .confirmed:return"已确认";case .synthesizing:return"合成中";case .ready:return"可播放";case .stale:return"正文已变化" }
    }
    private func voiceLabel(_ role: AudiobookRole) -> String {
        if role.voiceId.isEmpty { return role.engine == .system ? "系统默认" : "云端默认" }
        if role.engine == .system { return AVSpeechSynthesisVoice(identifier: role.voiceId)?.name ?? role.voiceId }
        return cloudVoices.first { $0.voiceId == role.voiceId }?.displayName ?? role.voiceId
    }
    private func segmentText(_ s: AudiobookSegment) -> String { let ns=currentChapterText as NSString;let start=max(0,min(ns.length,s.start)),end=max(start,min(ns.length,s.end));return ns.substring(with:NSRange(location:start,length:end-start)) }

    @MainActor private func loadAll() async {
        firstChapter=min(currentChapterIndex,maxChapter);lastChapter=firstChapter
        do { try await TTSVoiceLibrary.shared.ensurePresets(); cloudVoices = try await TTSVoiceLibrary.shared.voices(); roles=try await AudiobookRepository.shared.roles(bookId:book.id);segments=try await AudiobookRepository.shared.segments(bookId:book.id,chapterIndex:currentChapterIndex);chapterState=try await AudiobookRepository.shared.chapterState(bookId:book.id,chapterIndex:currentChapterIndex);syncPlayback();await updateEstimate() }
        catch { errorText=error.localizedDescription }
        policy=AudiobookEnginePolicy(rawValue:ttsStore.settings.audiobookEnginePolicy) ?? .narratorSystemCharactersAI
    }
    @MainActor private func extractRoles() async { busy=true;defer{busy=false};do{roles=try await AudiobookPlanner.shared.extractRoles(bookId:book.id);await autoAssignVoices();syncPlayback()}catch{errorText=error.localizedDescription} }
    @MainActor private func applyPolicy() async { do{try await AudiobookRepository.shared.applyPolicy(bookId:book.id,policy);ttsStore.settings.audiobookEnginePolicy=policy.rawValue;roles=try await AudiobookRepository.shared.roles(bookId:book.id);await autoAssignVoices();syncPlayback()}catch{errorText=error.localizedDescription} }
    @MainActor private func autoAssignVoices() async {
        do { let system=AVSpeechSynthesisVoice.speechVoices();let saved=try await TTSVoiceLibrary.shared.voices();for var role in roles{if role.engine == .system{if role.voiceId.isEmpty{let lang=ttsStore.settings.systemLanguageTag.nilIfEmpty ?? Locale.preferredLanguages.first ?? "zh-CN";let matches=system.filter{$0.language.hasPrefix(String(lang.prefix(2)))};role.voiceId=(matches.first?.identifier ?? AVSpeechSynthesisVoice(language:lang)?.identifier) ?? ""}}else if role.voiceId.isEmpty{let hint=ttsStore.settings.aiProvider == .gemini ? "GEMINI":(ttsStore.settings.aiProvider == .openAICompatible ? "OPENAI":"MINIMAX");let candidates=saved.filter{$0.providerHint == hint};let gender=role.gender.uppercased();role.voiceId=(candidates.first{!gender.isEmpty && $0.gender==gender} ?? candidates.first)?.voiceId ?? ttsStore.settings.aiVoiceId};_ = try await AudiobookRepository.shared.saveRole(role)};roles=try await AudiobookRepository.shared.roles(bookId:book.id);cloudVoices=saved;syncPlayback()}catch{errorText=error.localizedDescription}
    }
    @MainActor private func saveRole(_ role:AudiobookRole) async { do{_ = try await AudiobookRepository.shared.saveRole(role);editingRole=nil;roles=try await AudiobookRepository.shared.roles(bookId:book.id);chapterState=try await AudiobookRepository.shared.chapterState(bookId:book.id,chapterIndex:currentChapterIndex);syncPlayback();await updateEstimate()}catch{errorText=error.localizedDescription} }
    @MainActor private func generateScript() async { busy=true;defer{busy=false};do{segments=try await AudiobookPlanner.shared.script(bookId:book.id,chapterIndex:currentChapterIndex);chapterState=try await AudiobookRepository.shared.chapterState(bookId:book.id,chapterIndex:currentChapterIndex);syncPlayback();await updateEstimate()}catch{errorText=error.localizedDescription} }
    @MainActor private func confirmScript() async { do{try await AudiobookRepository.shared.confirmScript(bookId:book.id,chapterIndex:currentChapterIndex);chapterState=try await AudiobookRepository.shared.chapterState(bookId:book.id,chapterIndex:currentChapterIndex)}catch{errorText=error.localizedDescription} }
    @MainActor private func updateSegment(_ segment:AudiobookSegment,roleId:Int64) async { do{var copy=segment;copy.roleId=roleId;try await AudiobookRepository.shared.updateSegment(copy);segments=try await AudiobookRepository.shared.segments(bookId:book.id,chapterIndex:currentChapterIndex);chapterState=try await AudiobookRepository.shared.chapterState(bookId:book.id,chapterIndex:currentChapterIndex);syncPlayback();await updateEstimate()}catch{errorText=error.localizedDescription} }
    @MainActor private func refreshGeminiVoices() async { do{let count=try await TTSVoiceLibrary.shared.refreshGeminiCatalog();cloudVoices=try await TTSVoiceLibrary.shared.voices();errorText="已刷新 \(count) 个 Gemini 音色"}catch{errorText=error.localizedDescription} }
    @MainActor private func updateEstimate() async {
        do { let roleMap=Dictionary(uniqueKeysWithValues:roles.map{($0.id,$0)});var counts:[Int]=[],engines:[AudiobookEngine]=[];for idx in firstChapter...lastChapter{guard let ch=try await LibraryRepository.shared.chapter(bookId:book.id,index:idx) else{continue};let body=try await LibraryRepository.shared.chapterText(ch);let ns=body as NSString;for s in try await AudiobookRepository.shared.segments(bookId:book.id,chapterIndex:idx){counts.append(max(0,min(ns.length,s.end)-max(0,min(ns.length,s.start))));engines.append(s.roleId.flatMap{roleMap[$0]}?.engine ?? .system)}};estimate=AudiobookCostEstimator.estimate(characterCounts:counts,engines:engines,pricePerTenThousandChars:pricePerTenThousand)} catch { }
    }
    @MainActor private func startProduction() {
        let range=Array(firstChapter...lastChapter);productionTask?.cancel();productionTask=Task{do{_ = try await AudiobookProducer.shared.produce(bookId:book.id,chapterIndices:range){p in Task{@MainActor in productionProgress=p}};await MainActor.run{productionTask=nil};await loadAll()}catch is CancellationError{await MainActor.run{productionTask=nil}}catch{await MainActor.run{productionTask=nil;errorText=error.localizedDescription}}}
    }
    @MainActor private func syncPlayback(){guard chapters.indices.contains(currentChapterIndex) else{return};playback.load(book:book,chapter:chapters[currentChapterIndex],body:currentChapterText,roles:roles,segments:segments)}
}

private struct RoleEditorView:View{
    @Environment(\.dismiss) private var dismiss
    @State var role:AudiobookRole
    let cloudVoices:[TTSVoiceRecord]
    let onSave:(AudiobookRole)->Void
    private var systemVoices:[AVSpeechSynthesisVoice]{AVSpeechSynthesisVoice.speechVoices().sorted{$0.name<$1.name}}
    var body:some View{NavigationStack{Form{TextField("角色名",text:$role.name);Picker("引擎",selection:$role.engine){Text("系统 TTS").tag(AudiobookEngine.system);Text("AI TTS").tag(AudiobookEngine.ai)};if role.engine == .system{Picker("系统音色",selection:$role.voiceId){Text("系统默认").tag("");ForEach(systemVoices,id:\.identifier){Text("\($0.name) · \($0.language)").tag($0.identifier)}}}else{Picker("音色库",selection:$role.voiceId){Text("云端默认").tag("");ForEach(cloudVoices){Text("\($0.displayName) · \($0.tags)").tag($0.voiceId)}};TextField("或手工输入 Voice ID",text:$role.voiceId)};TextField("别名（逗号分隔）",text:Binding(get:{role.aliases.joined(separator:",")},set:{role.aliases=$0.split(separator:",").map{String($0).trimmingCharacters(in:.whitespacesAndNewlines)}}));TextField("性别 / 标签",text:$role.gender)}.navigationTitle(role.name).toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("保存"){onSave(role);dismiss()}.disabled(role.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}}}}
}

private extension String{var nilIfEmpty:String?{isEmpty ? nil:self}}
private extension Color{init?(hex:String){var raw=hex.trimmingCharacters(in:.whitespacesAndNewlines);if raw.hasPrefix("#"){raw.removeFirst()};guard raw.count==6,let v=UInt64(raw,radix:16) else{return nil};self.init(red:Double((v>>16)&255)/255,green:Double((v>>8)&255)/255,blue:Double(v&255)/255)}}
