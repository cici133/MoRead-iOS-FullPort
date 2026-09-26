import SwiftUI

struct WebSearchSettingsView:View{
    @ObservedObject private var store=WebSearchSettingsStore.shared
    @State private var testing=false
    @State private var message:String?
    var body:some View{
        Form{
            Section("网络搜索"){
                Toggle("允许伴读搜索互联网",isOn:$store.settings.enabled)
                Picker("服务商",selection:Binding(get:{store.settings.provider},set:{store.switchProvider($0)})){ForEach(WebSearchProvider.allCases,id:\.self){Text($0.label).tag($0)}}
                SecureField("API Key",text:$store.apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("搜索端点",text:Binding(get:{store.settings.searchEndpoints[store.settings.provider] ?? store.settings.provider.defaultSearchEndpoint},set:{store.settings.searchEndpoints[store.settings.provider]=$0})).textInputAutocapitalization(.never).keyboardType(.URL)
                TextField("抓取端点",text:Binding(get:{store.settings.scrapeEndpoints[store.settings.provider] ?? store.settings.provider.defaultScrapeEndpoint},set:{store.settings.scrapeEndpoints[store.settings.provider]=$0})).textInputAutocapitalization(.never).keyboardType(.URL)
                Button(testing ? "测试中…":"测试搜索"){test()}.disabled(testing || !store.settings.enabled)
            }
            Section{Text("开启后，伴读可以用 web_search 查询书外知识与近期事实，并用 web_scrape 抓取你或搜索结果提供的网址。工具不会读取未读正文，也不能扩大 ReadingScope。") .font(.footnote).foregroundStyle(.secondary)}
        }.navigationTitle("网络搜索").alert("提示",isPresented:Binding(get:{message != nil},set:{if !$0{message=nil}})){Button("好",role:.cancel){}}message:{Text(message ?? "")}
    }
    private func test(){testing=true;Task{@MainActor in do{let rows=try await WebSearchService.shared.search("OpenAI",limit:2);message=rows.isEmpty ? "服务可连接，但没有返回结果":"连接成功：\(rows.first?.title ?? "")"}catch{message=error.localizedDescription};testing=false}}
}
