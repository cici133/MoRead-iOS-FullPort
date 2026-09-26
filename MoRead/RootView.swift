import SwiftUI

enum AppRootDestination: String, CaseIterable, Identifiable {
    case library, companion, review, stats, settings
    var id: String { rawValue }
    var title: String { switch self { case .library: "书架"; case .companion: "伴读"; case .review: "回顾"; case .stats: "统计"; case .settings: "设置" } }
    var icon: String { switch self { case .library: "books.vertical"; case .companion: "sparkles"; case .review: "quote.bubble"; case .stats: "chart.bar"; case .settings: "gearshape" } }
    @ViewBuilder var content: some View {
        switch self {
        case .library: LibraryView()
        case .companion: CompanionHomeView()
        case .review: ReadingReviewView()
        case .stats: StatsView()
        case .settings: SettingsView()
        }
    }
}

struct RootView: View {
    @ObservedObject private var externalOpen = ExternalOpenCoordinator.shared
    @ObservedObject private var appearance = AppPlatformSettingsStore.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: AppRootDestination = .library

    var body: some View {
        Group {
            if horizontalSizeClass == .regular { tabletRoot }
            else if appearance.navigationStyle == .floating { floatingPhoneRoot }
            else { standardPhoneRoot }
        }
        .tint(appearance.accentColor)
        .environment(\.controlSize, appearance.shapeDensity == .spacious ? .large : .regular)
        .environment(\.font, appearance.appFont)
        .sheet(item: $externalOpen.pendingMDD) { pending in
            ExternalMDDTargetPicker(pending: pending)
        }
        .alert("文件处理", isPresented: Binding(get: { externalOpen.message != nil }, set: { if !$0 { externalOpen.message=nil } })) { Button("好",role:.cancel){} } message: { Text(externalOpen.message ?? "") }
    }

    private var standardPhoneRoot: some View {
        TabView(selection: $selection) {
            ForEach(AppRootDestination.allCases) { item in
                item.content.tag(item).tabItem { Label(item.title, systemImage: item.icon) }
            }
        }
    }

    private var floatingPhoneRoot: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                ForEach(AppRootDestination.allCases) { item in item.content.tag(item) }
            }
            .toolbar(.hidden, for: .tabBar)
            HStack(spacing: appearance.shapeDensity == .spacious ? 16 : 10) {
                ForEach(AppRootDestination.allCases) { item in
                    Button { selection = item } label: {
                        VStack(spacing: 3) {
                            Image(systemName: selection == item ? item.icon + ".fill" : item.icon).font(.system(size: 17, weight: selection == item ? .semibold : .regular))
                            Text(item.title).font(.caption2).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(selection == item ? appearance.accentColor : .secondary)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, appearance.shapeDensity == .spacious ? 12 : 8)
            .background(appearance.surfaceStyle == .glass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color(uiColor: .secondarySystemBackground)), in: Capsule())
            .overlay(Capsule().stroke(.primary.opacity(appearance.surfaceStyle == .glass ? 0.08 : 0.03)))
            .padding(.horizontal, 14).padding(.bottom, 6)
        }
        .safeAreaPadding(.bottom, 64)
    }

    private var tabletRoot: some View {
        NavigationSplitView {
            List {
                ForEach(AppRootDestination.allCases) { item in
                    Button { selection = item } label: {
                        HStack {
                            Label(item.title, systemImage: item.icon)
                            Spacer()
                            if selection == item { Image(systemName: "checkmark") }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("墨知 MoRead")
        } detail: {
            selection.content
        }
        .navigationSplitViewStyle(.balanced)
    }
}
