import AppKit
import SwiftUI

/// Headless rendering: `Awan --snapshot <name> <out.png> [width] [height]` renders a registered view
/// offscreen (works with the screen locked) — the visual instrument for every surface.
/// Each area registers its own views in `Snapshots+<Area>.swift` via `Snapshots.<area>(name)`.
@MainActor
enum Snapshots {
    static func run(_ args: [String]) -> Bool {
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 2 else { return false }
        let name = args[i + 1]
        let out = URL(fileURLWithPath: args[i + 2])
        let w = args.count > i + 3 ? Double(args[i + 3]) ?? 880 : 880
        let h = args.count > i + 4 ? Double(args[i + 4]) ?? 560 : 560
        AwanFont.registerBundled()
        DemoData.install()
        guard let view = view(named: name) else {
            FileHandle.standardError.write("unknown snapshot \(name). known: \(names.joined(separator: ", "))\n".data(using: .utf8)!)
            exit(2)
        }
        render(view, size: CGSize(width: w, height: h), to: out)
        return true
    }

    static var names: [String] { ["home", "home-settings", "notch-peek", "notch-activity"] + extraNames }
    static var extraNames: [String] { companionNames + companionExtraNames + agentNames + homeUINames + settingsNames + onboardingNames + overlayNames + extrasNames + skillsNames + charactersNames + notchNames }

    static func view(named name: String) -> AnyView? {
        let s = AppState.shared
        switch name {
        case "home":
            s.homePage = .home
            return AnyView(HomeRootView().environmentObject(s).environmentObject(s.agents).environmentObject(s.companion).environmentObject(RoutineScheduler.shared).environmentObject(Prefs.shared))
        case "home-settings":
            s.homePage = .settings(.general)
            return AnyView(HomeRootView().environmentObject(s).environmentObject(s.agents).environmentObject(s.companion).environmentObject(RoutineScheduler.shared).environmentObject(Prefs.shared))
        case "notch-peek":
            NotchController.shared.mode = .peek
            return AnyView(NotchRootView().environmentObject(s).environmentObject(NotchController.shared).background(Color(hex: 0x6B4FD8)))
        case "notch-activity":
            NotchController.shared.mode = .activity
            return AnyView(NotchRootView().environmentObject(s).environmentObject(NotchController.shared).background(Color(hex: 0x6B4FD8)))
        default:
            if let v = notch(name) { return v }
            return companion(name) ?? companionExtra(name) ?? agents(name) ?? homeUI(name) ?? settings(name) ?? onboarding(name) ?? overlay(name) ?? extras(name) ?? skills(name) ?? characters(name)
        }
    }

    static func render(_ view: AnyView, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        // let async work (thumbnails, task modifiers, animations) settle
        let until = Date().addingTimeInterval(0.8)
        while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot → \(url.path)")
    }
}
