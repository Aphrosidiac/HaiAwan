import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--snapshot") {
            MainActor.assumeIsolated { _ = NSApplication.shared; if Snapshots.run(CommandLine.arguments) { exit(0) } }
        }
        MainActor.assumeIsolated { AgentSelfTest.runIfRequested(CommandLine.arguments) } // agents builder: --agent-selftest
        if CommandLine.arguments.contains(where: { $0 == "--selftest" || $0 == "--companion-selftest" }) {
            MainActor.assumeIsolated { _ = NSApplication.shared; _ = CompanionSelfTest.runIfRequested(CommandLine.arguments) }
        }
        if CommandLine.arguments.contains("--update-selftest") {
            MainActor.assumeIsolated { _ = NSApplication.shared; UpdateSelfTest.run(CommandLine.arguments) }
        }
        if CommandLine.arguments.contains("--onboarding-selftest") {
            MainActor.assumeIsolated { _ = NSApplication.shared; OnboardingSelfTest.run(CommandLine.arguments) } // onboarding builder
        }
        if CommandLine.arguments.contains("--dictation-selftest") {
            MainActor.assumeIsolated { _ = NSApplication.shared; _ = DictationSelfTest.run(CommandLine.arguments) }
        }
        if MainActor.assumeIsolated({ AgentSelfTests.handles(CommandLine.arguments) }) {
            MainActor.assumeIsolated { AgentSelfTests.run(CommandLine.arguments) } // computer-use / connector self-tests
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState.shared

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AwanFont.registerBundled()
        applyDockPolicy()
        buildMainMenu()
        Log.info("Awan \(Bundle.main.shortVersion) launching")
        Log.info("permissions: " + PermissionKind.allCases.map { "\($0.rawValue) \(PermissionProbe.status($0))" }.joined(separator: ", "))

        ConnectorRuntimeBridge.install()
        _ = SettingsUI.shared   // listens for Help → Report a Bug before Settings is ever shown
        NotchController.shared.install()
        CursorOverlayController.shared.install()
        state.companion.start()
        state.routines.start()
        MorningSuggestions.shared.start()
        HotkeyMonitor.shared.start()
        if CommandLine.arguments.contains("--hotkey-selftest") { HotkeyMonitor.selfTest() }
        NotchExtras.start()   // wave 2: meetings, integration suggestions, "App updated"
        PaywallWindowController.shared.install()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { HomeWindowController.shared.prewarm() }
        Updater.shared.start() // Sparkle: hourly checks, EdDSA-verified downloads, install on quit

        Task {
            await state.bootstrap()
            // The two built-in Awans exist from the moment you're signed in (not only after onboarding),
            // so the notch peek and Home are never empty.
            if state.signInState == .signedIn { state.agents.seedStarterCastIfNeeded() }
            if !state.prefs.onboardingCompleted || state.signInState != .signedIn {
                OnboardingController.shared.begin()
            }
        }
        NotificationCenter.default.addObserver(forName: .awanDidSignIn, object: nil, queue: .main) { _ in
            Task { @MainActor in AppState.shared.agents.seedStarterCastIfNeeded() }
        }
        NotificationCenter.default.addObserver(forName: .awanOpenSettings, object: nil, queue: .main) { _ in
            Task { @MainActor in AppState.shared.openHome(.settings(.general)) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        state.openHome()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        state.agents.saveNow()
        state.agents.runner.interruptAll()
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        state.handle(url: url)
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(state.prefs.showInDock ? .regular : .accessory)
    }

    // MARK: Menu

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Awan", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Awan", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Awan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Open Home", action: #selector(openHome), keyEquivalent: "").target = self
        view.addItem(withTitle: "New Awan", action: #selector(newAwan), keyEquivalent: "n").target = self
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "What's New", action: #selector(openChangelog), keyEquivalent: "").target = self
        help.addItem(withTitle: "Report a Bug…", action: #selector(reportBug), keyEquivalent: "").target = self
        helpItem.submenu = help
        main.addItem(helpItem)

        NSApp.mainMenu = main
    }

    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Awan",
            .credits: NSAttributedString(string: "A friend that lives at the top of your screen.\nMade by FF Dev Studio."),
        ])
    }
    @objc func openSettings() { state.openHome(.settings(.general)) }
    @objc func openHome() { state.openHome() }
    @objc func newAwan() { state.openHome(.newAwan) }
    @objc func checkForUpdates() { Updater.shared.checkNow(userInitiated: true) }
    @objc func openChangelog() { NSWorkspace.shared.open(URL(string: "https://awan.ffdev.studio/changelog")!) }
    @objc func reportBug() { state.openHome(.settings(.general)); NotificationCenter.default.post(name: .awanReportBug, object: nil) }
}

extension Notification.Name {
    static let awanReportBug = Notification.Name("awanReportBug")
}

extension Bundle {
    var shortVersion: String { (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0" }
    var buildNumber: String { (infoDictionary?["CFBundleVersion"] as? String) ?? "1" }
}

/// Minimal file logger (Settings → Report a bug attaches the tail).
enum Log {
    static let url = Paths.logs.appendingPathComponent("awan.log")
    private static let queue = DispatchQueue(label: "awan.log")

    static func info(_ s: String) { write("INFO", s) }
    static func error(_ s: String) { write("ERROR", s) }

    private static func write(_ level: String, _ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(s)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        #if DEBUG
        print(line, terminator: "")
        #endif
    }

    static func tail(_ bytes: Int = 64_000) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data.suffix(bytes), as: UTF8.self)
    }
}
