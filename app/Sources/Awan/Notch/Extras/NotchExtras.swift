import Foundation

/// Wave-2 notch extras, started once at launch from AppDelegate:
/// handoff (HandoffManager, started by the ⌃⌥⇧ hotkey / the peek's viewfinder button), meeting countdown
/// (MeetingMonitor), integration suggestions (IntegrationSuggester), file drops (NotchDropController via
/// NotchRootView's drop delegate), the peek file pile (PeekFilePile) and "App updated" (AppUpdateNotice).
@MainActor
enum NotchExtras {
    static func start() {
        MeetingMonitor.shared.start()
        IntegrationSuggester.shared.start()
        AppUpdateNotice.checkOnLaunch()
        Task {
            // The suggester matches against the catalogue; make sure it's there (cached on disk after the first load).
            if ConnectorStore.shared.catalog.isEmpty { await ConnectorStore.shared.loadCatalog() }
        }
    }
}
