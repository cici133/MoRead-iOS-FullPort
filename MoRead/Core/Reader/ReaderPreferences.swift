import Foundation
import SwiftUI

enum ReaderLayoutMode: String, Codable, CaseIterable, Sendable { case scroll, paged }
enum ReaderWritingMode: String, Codable, CaseIterable, Sendable { case horizontal, vertical }
enum ReaderPageAnimation: String, Codable, CaseIterable, Sendable { case none, slide, cover, classicCurl, modernCurl }
enum ReaderPublisherStyleMode: String, Codable, CaseIterable, Sendable {
    case original, smart, takeover
    var label: String {
        switch self { case .original: return "原书优先"; case .smart: return "智能融合"; case .takeover: return "用户接管" }
    }
}


enum ReaderHardwareKey: String, Codable, CaseIterable, Sendable {
    case left, right, up, down, pageUp, pageDown, space, enter
    var label: String {
        switch self {
        case .left: return "←"; case .right: return "→"; case .up: return "↑"; case .down: return "↓"
        case .pageUp: return "Page Up"; case .pageDown: return "Page Down"; case .space: return "空格"; case .enter: return "回车"
        }
    }
}

struct ReaderKeyBindings: Codable, Equatable, Sendable {
    var actions: [ReaderHardwareKey: ReaderTapAction] = [
        .left: .previousPage, .up: .previousPage, .pageUp: .previousPage,
        .right: .nextPage, .down: .nextPage, .pageDown: .nextPage, .space: .nextPage,
        .enter: .menu
    ]
    func action(for key: ReaderHardwareKey) -> ReaderTapAction { actions[key] ?? .none }
}

struct ReaderTheme: Codable, Equatable, Sendable {
    var backgroundHex = "#FFFDF7"
    var foregroundHex = "#2B2926"
    var accentHex = "#8C6B4F"
    var imageBackgroundHex = "#FFFDF7"
    var backgroundImagePath: String? = nil
}

struct ReaderPreferences: Codable, Equatable, Sendable {
    var layoutMode: ReaderLayoutMode = .paged
    var writingMode: ReaderWritingMode = .horizontal
    var pageAnimation: ReaderPageAnimation = .slide
    var twoPageSpread = false
    var fontSize: Double = 20
    var lineHeight: Double = 1.75
    var paragraphSpacing: Double = 0.55
    var paragraphIndentEM: Double = 2
    var horizontalMargin: Double = 22
    var verticalMargin: Double = 18
    var fontFamily = "-apple-system"
    var titleFontFamily = "-apple-system"
    var publisherStyleMode: ReaderPublisherStyleMode = .smart
    var theme = ReaderTheme()
    var customCSS = ""
    var hideStatusBar = false
    /// nil follows the app/system default. iOS disables the idle timer only while ReaderView is visible.
    var keepScreenOn: Bool? = nil
    /// nil follows current system brightness; otherwise 0...1 and restored when leaving ReaderView.
    var screenBrightness: Double? = nil
    var tapZones = ReaderTapZones()
    var autoRead = AutoReadSettings()
    var chineseConversion: [Int64: ChineseConversionMode] = [:]
    var showTranslations = true
    /// Book-scoped bilingual visibility. Android keeps this as a set of book ids as well.
    var bilingualBooks: Set<Int64>? = nil
    /// Dictionary lookup is always available; this switch only controls inline saved-word aids.
    var englishLearningEnabled: Bool? = nil
    /// Bionic reading bolds the first half of English words without changing textContent.
    var englishBionicEnabled: Bool? = nil
    var keyBindings = ReaderKeyBindings()
    // Additive optionals keep older reader-settings.json files decodable.
    var themePresets: [NamedReaderThemePreset]? = nil
    var dayThemePresetId: String? = nil
    var nightThemePresetId: String? = nil
    var dayNightThemeAuto: Bool? = nil
    var bookThemeOverrides: [Int64: BookReaderThemeOverride]? = nil
}

@MainActor
final class ReaderSettingsStore: ObservableObject {
    static let shared = ReaderSettingsStore()
    @Published var preferences: ReaderPreferences { didSet { save() } }
    private let url: URL

    init() {
        let root = (try? MoReadDatabase.applicationDirectory()) ?? FileManager.default.temporaryDirectory
        url = root.appendingPathComponent("reader-settings.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(ReaderPreferences.self, from: data) { preferences = decoded }
        else { preferences = ReaderPreferences() }
    }

    func conversionMode(bookId: Int64) -> ChineseConversionMode { preferences.chineseConversion[bookId] ?? .off }
    func setConversion(_ mode: ChineseConversionMode, bookId: Int64) {
        if mode == .off { preferences.chineseConversion.removeValue(forKey: bookId) }
        else { preferences.chineseConversion[bookId] = mode }
    }
    func bilingualVisible(bookId: Int64) -> Bool { preferences.bilingualBooks?.contains(bookId) ?? false }
    func setBilingualVisible(_ visible: Bool, bookId: Int64) {
        var ids = preferences.bilingualBooks ?? []
        if visible { ids.insert(bookId) } else { ids.remove(bookId) }
        preferences.bilingualBooks = ids
    }
    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(preferences) { try? data.write(to: url, options: .atomic) }
    }
}
