import Foundation
import SwiftUI

enum ChatBubbleShape: String, Codable, CaseIterable, Sendable, Identifiable {
    case rounded = "ROUNDED", outlined = "OUTLINED", paper = "PAPER", glass = "GLASS"
    var id: String { rawValue }
    var label: String { switch self { case .rounded: "圆角"; case .outlined: "描边"; case .paper: "纸片"; case .glass: "玻璃" } }
}

struct PersonaChatAppearance: Codable, Equatable, Sendable {
    var backgroundImageId: String? = nil
    var backgroundDim: Double = 0.55
    var fontId: String? = nil // iOS uses PostScript name as stable font identity.
    var fontScale: Double = 1
    var bubbleShape: String = ChatBubbleShape.rounded.rawValue
    var assistantColorARGB: Int64? = nil
    var userColorARGB: Int64? = nil

    enum CodingKeys: String, CodingKey {
        case backgroundImageId = "background_image_id", backgroundDim = "background_dim", fontId = "font_id", fontScale = "font_scale", bubbleShape = "bubble_shape", assistantColorARGB = "assistant_color", userColorARGB = "user_color"
    }
    var shape: ChatBubbleShape { ChatBubbleShape(rawValue: bubbleShape) ?? .rounded }
    func sanitized() -> Self {
        var copy = self; copy.backgroundDim = min(1, max(0, backgroundDim)); copy.fontScale = min(1.6, max(0.8, fontScale)); copy.bubbleShape = copy.shape.rawValue; return copy
    }
    static func decode(_ raw: String?) -> Self { guard let raw, let data=raw.data(using:.utf8), let value=try? JSONDecoder().decode(Self.self,from:data) else{return .init()};return value.sanitized() }
    func encoded() -> String { String(data:(try? JSONEncoder().encode(sanitized())) ?? Data("{}".utf8),encoding:.utf8) ?? "{}" }

    func assistantColor(default color: Color = .secondary.opacity(0.10)) -> Color { colorFrom(argb: assistantColorARGB) ?? color }
    func userColor(default color: Color = .accentColor.opacity(0.14)) -> Color { colorFrom(argb: userColorARGB) ?? color }
    private func colorFrom(argb: Int64?) -> Color? {
        guard let argb else { return nil }; let value=UInt32(truncatingIfNeeded:argb)
        return Color(red:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255,opacity:Double((value>>24)&255)/255)
    }
}

struct PersonaChatBackdrop<Content: View>: View {
    let appearance: PersonaChatAppearance
    let imagePath: String?
    let content: Content

    init(appearance: PersonaChatAppearance, imagePath: String?, @ViewBuilder content: () -> Content) {
        self.appearance = appearance
        self.imagePath = imagePath
        self.content = content()
    }

    var body: some View {
        ZStack {
            if let imagePath, let image = UIImage(contentsOfFile: imagePath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .overlay(Color(.systemBackground).opacity(appearance.backgroundDim))
            }
            content
        }
    }
}

struct PersonaChatBubbleSurface<Content: View>: View {
    let role: ChatRole
    let appearance: PersonaChatAppearance
    let content: Content

    init(role: ChatRole, appearance: PersonaChatAppearance, @ViewBuilder content: () -> Content) {
        self.role = role
        self.appearance = appearance
        self.content = content()
    }

    private var tint: Color {
        role == .user ? appearance.userColor() : appearance.assistantColor()
    }
    private var radius: CGFloat {
        switch appearance.shape {
        case .rounded, .glass: return 14
        case .outlined: return 12
        case .paper: return 5
        }
    }
    private var textFont: Font {
        let size = 17.0 * appearance.fontScale
        if let name = appearance.fontId, !name.isEmpty { return .custom(name, size: size) }
        return .system(size: size)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .font(textFont)
            .padding(12)
            .background {
                switch appearance.shape {
                case .rounded:
                    shape.fill(tint)
                case .outlined:
                    shape.fill(Color.clear)
                case .paper:
                    shape.fill(tint.opacity(0.92))
                case .glass:
                    shape.fill(.ultraThinMaterial).overlay(shape.fill(tint.opacity(0.18)))
                }
            }
            .overlay {
                if appearance.shape == .outlined {
                    shape.stroke(tint.opacity(0.72), lineWidth: 1)
                }
            }
            .clipShape(shape)
    }
}
