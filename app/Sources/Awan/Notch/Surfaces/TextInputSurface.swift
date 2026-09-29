import SwiftUI
import AppKit

/// OWNER: companion builder — the double-tap-control text composer in the notch.
/// Single line, Enter sends, Esc closes. The notch panel is made key so typing lands here
/// while the app you were in stays frontmost (non-activating panel).
struct NotchTextInputSurface: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var companion = CompanionEngine.shared

    var body: some View {
        HStack(spacing: 12) {
            CloudCreature(appearance: .mascot, mood: companion.composerDraft.isEmpty ? .listening : .happy, glow: false)
                .frame(width: 30, height: 26)
            ComposerField(
                text: $companion.composerDraft,
                placeholder: companion.history.isEmpty ? "ask Awan…" : "ask a follow-up…",
                onSubmit: { companion.sendText(companion.composerDraft) },
                onCancel: { companion.closeTextComposer() }
            )
            .frame(height: 24)
            if companion.composerDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                CircleIconButton(systemName: "xmark", size: 24, help: "Close (esc)") { companion.closeTextComposer() }
            } else {
                Button { companion.sendText(companion.composerDraft) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Theme.textOnLime)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.lime))
                }
                .buttonStyle(.plain)
                .help("Send (return)")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 36)
    }
}

/// NSTextField bridge: grabs key focus when it appears, reports return / escape.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusingTextField {
        let f = FocusingTextField()
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.usesSingleLineMode = true
        f.lineBreakMode = .byTruncatingHead
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.font = Self.font
        f.textColor = NSColor(hex: 0xF3EFE4)
        f.delegate = context.coordinator
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: NSColor(hex: 0x8B8981), .font: Self.font])
        f.stringValue = text
        return f
    }

    func updateNSView(_ f: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        if f.placeholderAttributedString?.string != placeholder {
            f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: NSColor(hex: 0x8B8981), .font: Self.font])
        }
    }

    static var font: NSFont {
        NSFontManager.shared.font(withFamily: AwanFont.family, traits: [], weight: 5, size: 15) ?? .systemFont(ofSize: 15)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposerField
        init(_ p: ComposerField) { parent = p }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            // The notch panel is non-activating: it can take key focus without pulling the user's app back.
            window.makeKey()
            window.makeFirstResponder(self)
            let end = (self.stringValue as NSString).length
            self.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
    }
}

/// Hands keyboard focus back to the app the user was in once the composer closes (the notch panel stays on screen).
@MainActor
enum NotchFocus {
    private static var releaser: NSPanel?

    static func release() {
        guard let key = NSApp.keyWindow, key is NotchPanel else { return }
        let p = releaser ?? {
            let p = NSPanel(contentRect: NSRect(x: -10, y: -10, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.alphaValue = 0
            p.ignoresMouseEvents = true
            releaser = p
            return p
        }()
        p.makeKeyAndOrderFront(nil)
        p.orderOut(nil)
    }
}
