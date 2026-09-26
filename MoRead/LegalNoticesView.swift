import SwiftUI

struct LegalNoticesView: View {
    @State private var selection: LegalDocument = .license

    var body: some View {
        VStack(spacing: 0) {
            Picker("文档", selection: $selection) {
                ForEach(LegalDocument.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            ScrollView {
                Text(selection.text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom])
            }
        }
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum LegalDocument: CaseIterable {
    case license, notices

    var title: String { self == .license ? "GPL-3.0" : "第三方说明" }
    var resource: (String, String) {
        switch self {
        case .license: return ("GPL-3.0", "txt")
        case .notices: return ("THIRD_PARTY_NOTICES", "md")
        }
    }
    var text: String {
        let pair = resource
        guard let url = Bundle.main.url(forResource: pair.0, withExtension: pair.1),
              let value = try? String(contentsOf: url, encoding: .utf8) else {
            return "许可文档未能随 App 打包。请检查构建资源。"
        }
        return value
    }
}
