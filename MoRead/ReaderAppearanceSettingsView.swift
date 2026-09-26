import CoreText
import SwiftUI
import UIKit

struct ReaderAppearanceAdvancedView: View {
    @ObservedObject private var store = ReaderSettingsStore.shared
    @State private var importingBackground = false
    @State private var importingFont = false
    @State private var fonts: [ReaderFontAsset] = []
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("阅读主题") {
                NavigationLink("主题预设与日夜切换") { ReaderThemePresetManagerView() }
                ColorPicker("纸张颜色", selection: hexColor($store.preferences.theme.backgroundHex), supportsOpacity: false)
                ColorPicker("正文颜色", selection: hexColor($store.preferences.theme.foregroundHex), supportsOpacity: false)
                ColorPicker("强调色", selection: hexColor($store.preferences.theme.accentHex), supportsOpacity: false)
                if let path = store.preferences.theme.backgroundImagePath, FileManager.default.fileExists(atPath: path) {
                    HStack {
                        if let image = UIImage(contentsOfFile: path) { Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56).clipped().clipShape(RoundedRectangle(cornerRadius: 8)) }
                        Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                        Spacer()
                        Button("移除", role: .destructive) { store.preferences.theme.backgroundImagePath = nil }
                    }
                }
                Button("导入背景图") { importingBackground = true }
            }
            Section("阅读字体") {
                Picker("正文字体", selection: $store.preferences.fontFamily) {
                    Text("系统默认").tag("-apple-system")
                    ForEach(fonts) { Text($0.displayName).tag("'\($0.postScriptName)'") }
                }
                Picker("章首字体", selection: $store.preferences.titleFontFamily) {
                    Text("系统默认").tag("-apple-system")
                    ForEach(fonts) { Text($0.displayName).tag("'\($0.postScriptName)'") }
                }
                Button("导入 TTF / OTF") { importingFont = true }
                if !fonts.isEmpty {
                    ForEach(fonts) { font in
                        HStack { Text(font.displayName); Spacer(); Text(font.postScriptName).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            Section { Text("字体与背景只保存在应用私有目录，并随完整备份迁移。阅读字体与 App 界面字体互不影响。") .font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("主题、字体与背景")
        .task { reloadFonts() }
        .sheet(isPresented: $importingBackground) { ExtensionFilePicker(extensions: ["png","jpg","jpeg","webp"]) { urls in importingBackground=false; if let u=urls.first { importBackground(u) } } }
        .sheet(isPresented: $importingFont) { ExtensionFilePicker(extensions: ["ttf","otf"]) { urls in importingFont=false; if let u=urls.first { importFont(u) } } }
        .alert("导入失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText=nil } })) { Button("好", role:.cancel){} } message: { Text(errorText ?? "") }
    }

    private func importBackground(_ url: URL) {
        Task { @MainActor in
            do {
                let asset = try await ImageAssetLibrary.shared.importImage(from: url)
                try await ImageAssetLibrary.shared.update(id: asset.id, purpose: "阅读背景")
                store.preferences.theme.backgroundImagePath = asset.filePath
            } catch { errorText = error.localizedDescription }
        }
    }

    private func importFont(_ url: URL) {
        do {
            let access=url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let dir=AppPaths.readerCustom.appendingPathComponent("fonts",isDirectory:true);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let target=dir.appendingPathComponent("\(UUID().uuidString).\(url.pathExtension.lowercased())")
            try FileManager.default.copyItem(at:url,to:target)
            guard ReaderFontLibrary.register(target) != nil else { throw ReaderEnhancementError.message("无法读取字体，请确认文件是有效的 TTF / OTF") }
            reloadFonts()
        } catch { errorText=error.localizedDescription }
    }

    private func reloadFonts() { fonts=ReaderFontLibrary.assets() }
    private func hexColor(_ binding: Binding<String>) -> Binding<Color> { Binding(get: { Color(uiColor: UIColor(hexString: binding.wrappedValue)) }, set: { binding.wrappedValue = UIColor($0).hexRGB }) }
}

struct ReaderEnhancementSettingsView: View {
    @ObservedObject private var store = ReaderEnhancementSettingsStore.shared
    @State private var replacement: ReaderTextReplacementRule?
    @State private var syntax: ReaderSyntaxRule?
    @State private var titleEditor=false
    var body: some View {
        List {
            Section("正文净化 / 替换") {
                ForEach(store.settings.replacementRules) { rule in
                    Button { replacement = rule } label: { HStack { VStack(alignment:.leading){Text(rule.name);Text(rule.forListenOnly ? "仅听书 · \(rule.pattern)":"正文 · \(rule.pattern)").font(.caption).foregroundStyle(.secondary).lineLimit(1)};Spacer();Image(systemName:rule.enabled ? "checkmark.circle.fill":"circle")} }.buttonStyle(.plain)
                }.onDelete { store.settings.replacementRules.remove(atOffsets:$0) }
                Button("新建替换规则") { replacement = .init(id:Int64(Date().timeIntervalSince1970*1000)) }
            }
            Section("语法高亮") {
                ForEach(store.settings.syntaxRules) { rule in
                    Button { syntax = rule } label:{HStack{VStack(alignment:.leading){Text(rule.name);Text(rule.pattern).font(.caption).foregroundStyle(.secondary).lineLimit(1)};Spacer();Image(systemName:rule.enabled ? "checkmark.circle.fill":"circle")}}.buttonStyle(.plain)
                }.onDelete { store.settings.syntaxRules.remove(atOffsets:$0) }
                Button("新建高亮规则") { syntax = .init() }
            }
            Section("章首") {
                NavigationLink("章首样式库") { TitleStylePresetManagerView() }
                Button("快速编辑当前样式") { titleEditor = true }
            }
        }
        .navigationTitle("正文规则与章首")
        .sheet(item:$replacement) { value in ReplacementRuleEditor(rule:value){saveReplacement($0)} }
        .sheet(item:$syntax) { value in SyntaxRuleEditor(rule:value){saveSyntax($0)} }
        .sheet(isPresented:$titleEditor) { TitleStyleEditor(style:store.settings.titleStyle){store.settings.titleStyle=$0} }
    }
    private func saveReplacement(_ value:ReaderTextReplacementRule){if let i=store.settings.replacementRules.firstIndex(where:{$0.id==value.id}){store.settings.replacementRules[i]=value}else{store.settings.replacementRules.append(value)}}
    private func saveSyntax(_ value:ReaderSyntaxRule){if let i=store.settings.syntaxRules.firstIndex(where:{$0.id==value.id}){store.settings.syntaxRules[i]=value}else{store.settings.syntaxRules.append(value)}}
}

private struct ReplacementRuleEditor:View{
    @Environment(\.dismiss) private var dismiss;@State var rule:ReaderTextReplacementRule;let save:(ReaderTextReplacementRule)->Void;@State private var error:String?
    var body:some View{NavigationStack{Form{TextField("名称",text:$rule.name);TextField("匹配表达式",text:$rule.pattern,axis:.vertical).font(.system(.body,design:.monospaced));TextField("替换为",text:$rule.replacement,axis:.vertical);Toggle("启用",isOn:$rule.enabled);Toggle("正则表达式",isOn:$rule.isRegex);Toggle("忽略大小写",isOn:$rule.ignoreCase);Toggle("仅听书 / 有声书净化",isOn:$rule.forListenOnly)}.navigationTitle("替换规则").toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("保存"){do{_ = try rule.regex();save(rule);dismiss()}catch{self.error=error.localizedDescription}}}}.alert("规则无效",isPresented:Binding(get:{error != nil},set:{if !$0{error=nil}})){Button("好",role:.cancel){}}message:{Text(error ?? "")}}}
}

private struct SyntaxRuleEditor:View{
    @Environment(\.dismiss) private var dismiss;@State var rule:ReaderSyntaxRule;let save:(ReaderSyntaxRule)->Void
    var body:some View{NavigationStack{Form{TextField("名称",text:$rule.name);TextField("正则表达式",text:$rule.pattern,axis:.vertical).font(.system(.body,design:.monospaced));Toggle("启用",isOn:$rule.enabled);Toggle("忽略大小写",isOn:$rule.ignoreCase);ColorPicker("文字颜色",selection:Binding(get:{Color(uiColor:UIColor(hexString:rule.colorHex))},set:{rule.colorHex=UIColor($0).hexRGB}),supportsOpacity:false);ColorPicker("背景颜色",selection:Binding(get:{Color(uiColor:UIColor(hexString:rule.backgroundHex))},set:{rule.backgroundHex=UIColor($0).hexRGB}),supportsOpacity:false);Toggle("粗体",isOn:$rule.bold);Toggle("斜体",isOn:$rule.italic);Toggle("下划线",isOn:$rule.underline)}.navigationTitle("语法高亮").toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("保存"){if (try? NSRegularExpression(pattern:rule.pattern)) != nil{save(rule);dismiss()}}}}}}
}

private struct TitleStyleEditor:View{
    @Environment(\.dismiss) private var dismiss;@State var style:ReaderTitleStyle;let save:(ReaderTitleStyle)->Void
    var body:some View{NavigationStack{Form{Toggle("显示阅读器章首",isOn:$style.enabled);TextField("字体族",text:$style.fontFamily);Stepper("字号 \(style.fontSizeEm,specifier:"%.2f") em",value:$style.fontSizeEm,in:0.8...3,step:0.05);Picker("对齐",selection:$style.alignment){Text("左").tag("left");Text("中").tag("center");Text("右").tag("right")};TextField("文字颜色 Hex（空=正文）",text:$style.colorHex);TextField("背景颜色 Hex（可空）",text:$style.backgroundHex);Stepper("上间距 \(style.marginTopEm,specifier:"%.1f") em",value:$style.marginTopEm,in:0...6,step:0.1);Stepper("下间距 \(style.marginBottomEm,specifier:"%.1f") em",value:$style.marginBottomEm,in:0...6,step:0.1);Stepper("内边距 \(style.paddingEm,specifier:"%.1f") em",value:$style.paddingEm,in:0...4,step:0.1);TextField("边框颜色 Hex（可空）",text:$style.borderColorHex);Stepper("边框 \(style.borderWidthEm,specifier:"%.2f") em",value:$style.borderWidthEm,in:0...0.5,step:0.02);Stepper("圆角 \(style.borderRadiusEm,specifier:"%.1f") em",value:$style.borderRadiusEm,in:0...4,step:0.1)}.navigationTitle("章首样式").toolbar{ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}};ToolbarItem(placement:.confirmationAction){Button("保存"){save(style);dismiss()}}}}}
}

struct ReaderFontAsset:Identifiable,Hashable{var id:String{path};var displayName:String;var postScriptName:String;var path:String}
enum ReaderFontLibrary{
    static func directory()->URL{AppPaths.readerCustom.appendingPathComponent("fonts",isDirectory:true)}
    static func register(_ url:URL)->ReaderFontAsset?{var error:Unmanaged<CFError>?;CTFontManagerRegisterFontsForURL(url as CFURL,.process,&error);guard let provider=CGDataProvider(url:url as CFURL),let font=CGFont(provider),let ps=font.postScriptName as String? else{return nil};return .init(displayName:(font.fullName as String?) ?? ps,postScriptName:ps,path:url.path)}
    static func assets()->[ReaderFontAsset]{let dir=directory();try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);return (try? FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil))?.compactMap(register).sorted{$0.displayName.localizedCaseInsensitiveCompare($1.displayName)== .orderedAscending} ?? []}
}

private extension UIColor{
    convenience init(hexString:String){let s=hexString.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"#",with:"");let v=UInt64(s,radix:16) ?? 0;let r,g,b:CGFloat;if s.count==6{r=CGFloat((v>>16)&255)/255;g=CGFloat((v>>8)&255)/255;b=CGFloat(v&255)/255}else{r=1;g=1;b=1};self.init(red:r,green:g,blue:b,alpha:1)}
    var hexRGB:String{var r:CGFloat=0,g:CGFloat=0,b:CGFloat=0,a:CGFloat=0;getRed(&r,green:&g,blue:&b,alpha:&a);return String(format:"#%02X%02X%02X",Int(r*255),Int(g*255),Int(b*255))}
}
