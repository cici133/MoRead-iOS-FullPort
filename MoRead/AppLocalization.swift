import Foundation
import SwiftUI

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system, zhHans, english
    var id: String { rawValue }
    var label: String {
        switch self { case .system: return "跟随系统"; case .zhHans: return "简体中文"; case .english: return "English" }
    }
    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .english: return Locale(identifier: "en")
        }
    }
}
