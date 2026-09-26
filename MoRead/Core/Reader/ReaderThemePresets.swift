import Foundation

struct NamedReaderThemePreset: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var name: String = "阅读主题"
    var theme = ReaderTheme()
    var fontSize: Double = 20
    var lineHeight: Double = 1.75
    var paragraphSpacing: Double = 0.55
    var paragraphIndentEM: Double = 2
    var horizontalMargin: Double = 22
    var verticalMargin: Double = 18
    var fontFamily: String = "-apple-system"
    var titleFontFamily: String = "-apple-system"
    var publisherStyleMode: ReaderPublisherStyleMode = .smart
    var customCSS: String = ""
    var titleStyle = ReaderTitleStyle()
    var isDark: Bool? = nil

    init(id: String = UUID().uuidString, name: String, preferences: ReaderPreferences, titleStyle: ReaderTitleStyle, isDark: Bool? = nil) {
        self.id = id
        self.name = name
        theme = preferences.theme
        fontSize = preferences.fontSize
        lineHeight = preferences.lineHeight
        paragraphSpacing = preferences.paragraphSpacing
        paragraphIndentEM = preferences.paragraphIndentEM
        horizontalMargin = preferences.horizontalMargin
        verticalMargin = preferences.verticalMargin
        fontFamily = preferences.fontFamily
        titleFontFamily = preferences.titleFontFamily
        publisherStyleMode = preferences.publisherStyleMode
        customCSS = preferences.customCSS
        self.titleStyle = titleStyle
        self.isDark = isDark
    }
}

struct BookReaderThemeOverride: Codable, Equatable, Hashable, Sendable {
    var enabled = false
    var dayPresetId: String?
    var nightPresetId: String?
}

extension ReaderPreferences {
    var resolvedThemePresets: [NamedReaderThemePreset] { themePresets ?? [] }
    var resolvedBookThemeOverrides: [Int64: BookReaderThemeOverride] { bookThemeOverrides ?? [:] }
    var automaticDayNightThemeEnabled: Bool { dayNightThemeAuto ?? false }

    func selectedThemePreset(bookId: Int64?, isDark: Bool) -> NamedReaderThemePreset? {
        let presets = resolvedThemePresets
        let override = bookId.flatMap { resolvedBookThemeOverrides[$0] }.flatMap { $0.enabled ? $0 : nil }
        let globalId = automaticDayNightThemeEnabled && isDark ? nightThemePresetId : dayThemePresetId
        let chosenId = override.flatMap { automaticDayNightThemeEnabled && isDark ? $0.nightPresetId : $0.dayPresetId } ?? globalId
        return chosenId.flatMap { id in presets.first { $0.id == id } }
    }

    func applying(_ preset: NamedReaderThemePreset?) -> ReaderPreferences {
        guard let preset else { return self }
        var copy = self
        copy.theme = preset.theme
        copy.fontSize = preset.fontSize.clamped(to: 12...40)
        copy.lineHeight = preset.lineHeight.clamped(to: 1.1...2.6)
        copy.paragraphSpacing = preset.paragraphSpacing.clamped(to: 0...2)
        copy.paragraphIndentEM = preset.paragraphIndentEM.clamped(to: 0...4)
        copy.horizontalMargin = preset.horizontalMargin.clamped(to: 0...96)
        copy.verticalMargin = preset.verticalMargin.clamped(to: 0...96)
        copy.fontFamily = preset.fontFamily
        copy.titleFontFamily = preset.titleFontFamily
        copy.publisherStyleMode = preset.publisherStyleMode
        copy.customCSS = preset.customCSS
        return copy
    }
}

extension ReaderSettingsStore {
    func resolvedPreferences(bookId: Int64?, isDark: Bool) -> ReaderPreferences {
        preferences.applying(preferences.selectedThemePreset(bookId: bookId, isDark: isDark))
    }

    func resolvedTitleStyle(bookId: Int64?, isDark: Bool, fallback: ReaderTitleStyle) -> ReaderTitleStyle {
        preferences.selectedThemePreset(bookId: bookId, isDark: isDark)?.titleStyle ?? fallback
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
