import SwiftUI

/// Snapshot registrations for the companion area. Add cases here; keep names prefixed "companion-".
extension Snapshots {
    static var companionNames: [String] { ["companion-text-input", "companion-text-input-typed", "companion-text-response", "companion-text-response-streaming"] }

    static func companion(_ name: String) -> AnyView? {
        let c = CompanionEngine.shared
        let notch = NotchController.shared
        func surface(_ kind: NotchSurfaceKind) -> AnyView {
            notch.mode = .surface(kind)
            let size = notch.sizeFor(.surface(kind))
            return AnyView(
                ZStack(alignment: .top) {
                    Color(hex: 0x6B4FD8)
                    NotchRootView().environmentObject(AppState.shared).environmentObject(notch)
                        .frame(width: size.width, height: size.height)
                }
            )
        }
        switch name {
        case "companion-text-input":
            c.debugSeed(user: "", reply: "", draft: "", streaming: false)
            return surface(.textInput)
        case "companion-text-input-typed":
            c.debugSeed(user: "", reply: "", draft: "how do I export this as a PDF?", streaming: false)
            return surface(.textInput)
        case "companion-text-response":
            c.debugSeed(user: "how do I export this as a PDF?",
                        reply: "open the file menu up top and pick export as pdf. it'll ask where to save, and the desktop is fine. if you want smaller files, the quartz filter in that same dialog can shrink it.",
                        draft: "", streaming: false)
            return surface(.textResponse)
        case "companion-text-response-streaming":
            c.debugSeed(user: "what's the difference between margin and padding?",
                        reply: "padding is the space inside the box, between the border and the content. margin is the space outside",
                        draft: "", streaming: true)
            return surface(.textResponse)
        default:
            return nil
        }
    }
}
