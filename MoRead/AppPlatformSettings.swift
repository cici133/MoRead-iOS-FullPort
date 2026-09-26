import SwiftUI

enum AppColorMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }
    var scheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

@MainActor
final class AppPlatformSettingsStore: ObservableObject {
    static let shared = AppPlatformSettingsStore()
    @AppStorage("app.color.mode") private var stored = "system"
    @AppStorage("app.language") private var storedLanguage = "system"
    @AppStorage("app.palette") private var storedPalette = "original"
    @AppStorage("app.accent.hex") private var storedAccent = "#7E9CB5"
    @AppStorage("app.surface.style") private var storedSurface = "glass"
    @AppStorage("app.nav.style") private var storedNavigation = "floating"
    @AppStorage("app.shape.density") private var storedDensity = "standard"
    @AppStorage("app.font.postscript") private var storedAppFont = ""
    @Published var colorMode: AppColorMode = .system { didSet { stored = colorMode.rawValue } }
    @Published var language: AppLanguage = .system { didSet { storedLanguage = language.rawValue } }
    @Published var palette: AppPaletteScheme = .original { didSet { storedPalette = palette.rawValue } }
    @Published var accentHex: String = "#7E9CB5" { didSet { storedAccent = accentHex } }
    @Published var surfaceStyle: AppSurfaceStyle = .glass { didSet { storedSurface = surfaceStyle.rawValue } }
    @Published var navigationStyle: AppNavigationStyle = .floating { didSet { storedNavigation = navigationStyle.rawValue } }
    @Published var shapeDensity: AppShapeDensity = .standard { didSet { storedDensity = shapeDensity.rawValue } }
    @Published var appFontPostScriptName: String = "" { didSet { storedAppFont = appFontPostScriptName } }
    private init() {
        colorMode = AppColorMode(rawValue: stored) ?? .system
        language = AppLanguage(rawValue: storedLanguage) ?? .system
        palette = AppPaletteScheme(rawValue: storedPalette) ?? .original
        accentHex = storedAccent
        surfaceStyle = AppSurfaceStyle(rawValue: storedSurface) ?? .glass
        navigationStyle = AppNavigationStyle(rawValue: storedNavigation) ?? .floating
        shapeDensity = AppShapeDensity(rawValue: storedDensity) ?? .standard
        appFontPostScriptName = storedAppFont
    }

    func applyPalette(_ value: AppPaletteScheme) {
        palette = value
        accentHex = value.recommendedAccentHex
        if value == .original { surfaceStyle = .glass; navigationStyle = .floating; shapeDensity = .standard }
    }
}

struct PendingExternalMDD: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
}

@MainActor
final class ExternalOpenCoordinator: ObservableObject {
    static let shared = ExternalOpenCoordinator()
    @Published var message: String?
    @Published var pendingMDD: PendingExternalMDD?

    func open(_ url: URL, store: LibraryStore) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            switch url.pathExtension.lowercased() {
            case "mdx":
                _ = try await LocalDictionaryRepository.shared.importMdx(from: url)
                message = "词典已导入"
            case "mdd":
                let root = try MoReadDatabase.applicationDirectory().appendingPathComponent("external-mdd-inbox", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let target = root.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                try FileManager.default.copyItem(at: url, to: target)
                pendingMDD = PendingExternalMDD(url: target, name: url.lastPathComponent)
            case "txt":
                let source = try await Task.detached(priority: .userInitiated) { try TextImporter.loadSource(url: url) }.value
                let draft = TextImporter.importedBook(source: source, sourceURL: url)
                try await store.importBook(draft)
                message = "《\(draft.title)》已导入"
            case "epub":
                let draft = try await BookImportService.importBook(url: url)
                try await store.importBook(draft)
                message = "《\(draft.title)》已导入"
            default:
                throw ExternalOpenError.unsupported
            }
        } catch {
            message = "打开失败：\(error.localizedDescription)"
        }
    }

    func finishMDDImport(dictionaryId: String) async {
        guard let pendingMDD else { return }
        do {
            let result = try await LocalDictionaryRepository.shared.importResources(dictionaryId: dictionaryId, urls: [pendingMDD.url])
            message = result.imported > 0 ? "MDD 资源包已加入词典" : "该 MDD 已存在，未重复导入"
            try? FileManager.default.removeItem(at: pendingMDD.url)
            self.pendingMDD = nil
        } catch {
            message = "MDD 导入失败：\(error.localizedDescription)"
        }
    }

    func cancelMDDImport() {
        if let pendingMDD { try? FileManager.default.removeItem(at: pendingMDD.url) }
        self.pendingMDD = nil
    }
}

enum ExternalOpenError: LocalizedError {
    case unsupported
    var errorDescription: String? { "不支持这种文件类型" }
}

struct AppAppearanceSettingsView: View {
    @ObservedObject private var store = AppPlatformSettingsStore.shared
    var body: some View {
        Form {
            Section("界面语言") {
                Picker("界面语言", selection: $store.language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                Text("英文翻译仍在完善，尚未翻译的 iOS 新增文字以中文显示。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("界面明暗") {
                Picker("外观", selection: $store.colorMode) {
                    ForEach(AppColorMode.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("主题方案") {
                Picker("配色", selection: Binding(get: { store.palette }, set: { store.applyPalette($0) })) {
                    ForEach(AppPaletteScheme.allCases) { Text($0.label).tag($0) }
                }
                ColorPicker("强调色", selection: Binding(get: { store.accentColor }, set: { store.accentHex = UIColor($0).moreadHexRGB }), supportsOpacity: false)
                Picker("界面质感", selection: $store.surfaceStyle) { ForEach(AppSurfaceStyle.allCases) { Text($0.label).tag($0) } }
                Picker("导航样式", selection: $store.navigationStyle) { ForEach(AppNavigationStyle.allCases) { Text($0.label).tag($0) } }
                Picker("形状与密度", selection: $store.shapeDensity) { ForEach(AppShapeDensity.allCases) { Text($0.label).tag($0) } }
            }
            Section {
                Text("iOS 端跟随系统动态字体与无障碍设置；阅读纸色、阅读字体和背景图仍在“阅读与外观”中独立配置。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("应用外观")
    }
}

enum AppPaletteScheme: String, Codable, CaseIterable, Identifiable {
    case mist, sage, rose, graphite, original
    var id: String { rawValue }
    var label: String { switch self { case .mist: "雾蓝"; case .sage: "青竹"; case .rose: "灰粉"; case .graphite: "灰阶"; case .original: "原版" } }
    var recommendedAccentHex: String { switch self { case .mist: "#6A94B5"; case .sage: "#739278"; case .rose: "#AA7D86"; case .graphite: "#777777"; case .original: "#7E9CB5" } }
}

enum AppSurfaceStyle: String, Codable, CaseIterable, Identifiable {
    case glass, flat
    var id: String { rawValue }
    var label: String { self == .glass ? "玻璃浮层" : "扁平色块" }
}

enum AppNavigationStyle: String, Codable, CaseIterable, Identifiable {
    case floating, fullBar
    var id: String { rawValue }
    var label: String { self == .floating ? "悬浮胶囊" : "通栏导航" }
}

enum AppShapeDensity: String, Codable, CaseIterable, Identifiable {
    case standard, spacious
    var id: String { rawValue }
    var label: String { self == .standard ? "标准" : "舒展" }
}

extension AppPlatformSettingsStore {
    var accentColor: Color { Color(moreadHex: accentHex) ?? .accentColor }
    var floatingMaterial: Material { surfaceStyle == .glass ? .ultraThinMaterial : .regularMaterial }
    var appFont: Font? { appFontPostScriptName.isEmpty ? nil : .custom(appFontPostScriptName, size: 17, relativeTo: .body) }
}

extension Color {
    init?(moreadHex: String) {
        var raw = moreadHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt64(raw, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

private extension UIColor {
    var moreadHexRGB: String {
        var r: CGFloat=0,g: CGFloat=0,b: CGFloat=0,a: CGFloat=0
        getRed(&r, green:&g, blue:&b, alpha:&a)
        return String(format:"#%02X%02X%02X",Int(round(r*255)),Int(round(g*255)),Int(round(b*255)))
    }
}
