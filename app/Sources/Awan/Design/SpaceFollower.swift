import AppKit

/// Makes sure a panel shows on the Space the user is looking at — including another app's
/// full-screen Space, where `.canJoinAllSpaces` alone can leave it stranded on the desktop Space.
enum SpaceFollower {
    @MainActor
    static func bringToActiveSpace(_ window: NSWindow) {
        guard !window.isOnActiveSpace else { return }
        let original = window.collectionBehavior
        window.orderOut(nil)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        window.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if window.isOnActiveSpace { window.collectionBehavior = original.union(.fullScreenAuxiliary) }
            Log.info("space follower: \(window.className) activeSpace=\(window.isOnActiveSpace)")
        }
    }
}
