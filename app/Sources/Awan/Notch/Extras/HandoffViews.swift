import AppKit
import SwiftUI

/// The bar that appears beside a freshly drawn box (reference: HandoffPostDragActionBarView).
struct HandoffActionBar: View {
    @EnvironmentObject var handoff: HandoffManager
    @EnvironmentObject var agents: AgentStore
    @ObservedObject private var companion = CompanionEngine.shared

    static let size = CGSize(width: 580, height: 108)

    /// Below the box, else above it, else tucked inside its bottom edge; always on screen (flipped coords).
    static func origin(for r: CGRect, in bounds: CGSize) -> CGPoint {
        let s = size, gap: CGFloat = 12, margin: CGFloat = 12
        var y = r.maxY + gap
        if y + s.height > bounds.height - margin { y = r.minY - s.height - gap }
        if y < margin { y = min(bounds.height - s.height - margin, max(margin, r.maxY - s.height - gap)) }
        let x = min(max(margin, r.midX - s.width / 2), bounds.width - s.width - margin)
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let r = handoff.current {
                    RegionThumb(image: r.image, side: 34, badge: handoff.queued.isEmpty ? nil : handoff.payload.count)
                }
                if handoff.listening {
                    Button { handoff.stopVoice() } label: {
                        HStack(spacing: 9) {
                            WaveformBars(level: CGFloat(companion.audioLevel), color: Theme.ink).frame(width: 26, height: 13)
                            Text(companion.liveTranscript.isEmpty ? "Listening… click to stop" : companion.liveTranscript)
                                .lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 0)
                            Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                        }
                        .font(.awan(13, .semibold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(Capsule().fill(Theme.lime))
                    }
                    .buttonStyle(.plain)
                } else {
                    ComposerField(text: $handoff.comment, placeholder: "Add a note, or just pick where it goes…",
                                  onSubmit: { handoff.askAwan() }, onCancel: { handoff.cancel() })
                        .frame(height: 22)
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
                    CircleIconButton(systemName: "mic.fill", size: 30, filled: true, help: "Ask by voice") { handoff.askByVoice() }
                }
            }
            HStack(spacing: 8) {
                Button { handoff.askAwan() } label: { Label("Ask Awan", systemImage: "sparkles") }
                    .buttonStyle(.gel(.lime, height: 30, padding: 13, fontSize: 12.5))
                PopupMenuButton(title: "Send to an Awan", systemImage: "arrow.up.right.circle", items: awanItems)
                PopupMenuButton(title: "Paste into", systemImage: "doc.on.clipboard", items: pasteItems)
                Spacer(minLength: 4)
                Button { handoff.queueOnly() } label: { Label("Queue", systemImage: "square.stack") }
                    .buttonStyle(.gel(.dark, height: 30, padding: 12, fontSize: 12.5))
                    .help("Keep this box and add more before sending")
                CircleIconButton(systemName: "xmark", size: 28, help: "Cancel (esc)") { handoff.cancel() }
            }
            .disabled(handoff.listening)
            .opacity(handoff.listening ? 0.5 : 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: 0x1A1A18).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .preferredColorScheme(.dark)
    }

    private var awanItems: [PopupMenuButton.Item] {
        let list = agents.visibleAgents
        if list.isEmpty { return [.init(title: "No Awans yet", enabled: false) {}] }
        return list.map { a in .init(title: a.name) { handoff.send(to: a.slug) } }
    }

    private var pasteItems: [PopupMenuButton.Item] {
        let apps = HandoffTargetApp.available
        var items: [PopupMenuButton.Item] = apps.isEmpty
            ? [.init(title: "Open Terminal, iTerm, Claude, Cursor, Codex or VS Code first", enabled: false) {}]
            : apps.map { app in .init(title: app.name) { handoff.paste(into: app) } }
        items.append(.separator)
        items.append(.init(title: "Press Return after pasting", checked: handoff.pressReturn) { handoff.pressReturn.toggle() })
        return items
    }
}

/// A dark gel pill that pops an AppKit menu (SwiftUI menus can't take the gel look).
struct PopupMenuButton: View {
    struct Item {
        var title: String
        var enabled = true
        var checked = false
        var isSeparator = false
        var action: () -> Void
        static let separator = Item(title: "", isSeparator: true) {}
    }

    let title: String
    let systemImage: String
    let items: [Item]

    var body: some View {
        Button {
            MenuPopper.pop(items)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).opacity(0.7)
            }
        }
        .buttonStyle(.gel(.dark, height: 30, padding: 12, fontSize: 12.5))
    }
}

@MainActor
enum MenuPopper {
    private final class Target: NSObject {
        let actions: [() -> Void]
        init(_ a: [() -> Void]) { actions = a }
        @objc func fire(_ sender: NSMenuItem) { actions[sender.tag]() }
    }
    private static var target: Target?

    static func pop(_ items: [PopupMenuButton.Item]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let t = Target(items.map(\.action))
        target = t
        for (i, item) in items.enumerated() {
            if item.isSeparator { menu.addItem(.separator()); continue }
            let mi = NSMenuItem(title: item.title, action: #selector(Target.fire(_:)), keyEquivalent: "")
            mi.target = t
            mi.tag = i
            mi.isEnabled = item.enabled
            mi.state = item.checked ? .on : .off
            menu.addItem(mi)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// A captured region as a small tile, with a count badge when others are queued.
struct RegionThumb: View {
    let image: CGImage
    var side: CGFloat = 34
    var badge: Int? = nil
    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable().aspectRatio(contentMode: .fill)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous).strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text("\(badge)").font(.awan(10, .bold)).foregroundStyle(Theme.ink)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Circle().fill(Theme.lime))
                        .offset(x: 6, y: -6)
                }
            }
    }
}

/// Notch card: "Region queued" / "3 regions queued" / "Sent to Ship Lab" / "Pasted into Terminal".
struct HandoffSurface: View {
    @ObservedObject private var handoff = HandoffManager.shared

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.awan(14, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle).font(.awan(12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if case .queued = handoff.status {
                HStack(spacing: 6) {
                    Button("Clear") { handoff.clearQueue() }.buttonStyle(.gel(.dark, height: 26, padding: 11, fontSize: 12))
                    Button { handoff.beginRegionSelect() } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(.gel(.bone, height: 26, padding: 11, fontSize: 12))
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 22).padding(.top, 36)
    }

    @ViewBuilder private var icon: some View {
        switch handoff.status {
        case .queued:
            ZStack {
                ForEach(Array(handoff.queued.suffix(3).enumerated()), id: \.element.id) { i, r in
                    RegionThumb(image: r.image, side: 34)
                        .rotationEffect(.degrees(Double(i - 1) * 7))
                        .offset(x: CGFloat(i - 1) * 5)
                }
            }
            .frame(width: 46, height: 42)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 20)).foregroundStyle(Theme.warning).frame(width: 46)
        default:
            ZStack {
                Circle().fill(Theme.lime).frame(width: 34, height: 34)
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
            }
            .frame(width: 46)
        }
    }

    private var title: String {
        switch handoff.status {
        case let .queued(n): return n == 1 ? "Region queued" : "\(n) regions queued"
        case let .sent(name): return "Sent to \(name)"
        case let .pasted(app): return "Pasted into \(app)"
        case .asked: return "Asked Awan"
        case .failed: return "Didn't go through"
        case nil: return "Handoff"
        }
    }

    private var subtitle: String {
        switch handoff.status {
        case .queued: return "They go along with your next send."
        case .sent: return "It's in their tmp folder, and they're on it."
        case .pasted: return handoff.pressReturn ? "Pasted and sent." : "Pasted. Press Return when you're ready."
        case .asked: return "Looking at your box now."
        case let .failed(why): return why
        case nil: return ""
        }
    }
}
