import SwiftUI

@main
struct MoReadApp: App {
    @StateObject private var store: LibraryStore
    @StateObject private var platformSettings = AppPlatformSettingsStore.shared
    @StateObject private var externalOpen = ExternalOpenCoordinator.shared
    init() {
        // Apply a previously validated restore before any SQLite/DataStore singleton opens.
        try? BackupArchiveManager.applyPendingRestore()
        BackupBackgroundScheduler.register()
        BackupBackgroundScheduler.resumeStoredPreference()
        _store = StateObject(wrappedValue: LibraryStore())
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(platformSettings.colorMode.scheme)
                .environment(\.locale, platformSettings.language.locale)
                .onOpenURL { url in Task { await externalOpen.open(url, store: store) } }
        }
    }
}
