import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files dragged onto the notch (reference v1.0.52). While a drag hovers, the notch widens into a row of drop
/// targets: the mascot, then the roster. Dropping on an Awan copies the files into its workspace `tmp/` and sends
/// "Take a look at these files: …"; dropping on the mascot opens a quick composer — "What should I do with these?" —
/// and the best-suited Awan gets the files with the answer.
@MainActor
final class NotchDropController: ObservableObject {
    static let shared = NotchDropController()

    @Published private(set) var isDragging = false
    /// 0 = the mascot, 1… = `NotchDropLayout.targets` index + 1.
    @Published private(set) var hoverSlot: Int?
    /// Files waiting on the mascot's composer.
    @Published private(set) var pendingFiles: [URL] = []
    @Published var composerDraft = ""

    private var exitTask: Task<Void, Never>?

    var targets: [AwanAgent] { NotchDropLayout.targets(AgentStore.shared.visibleAgents) }

    func dragEntered() {
        exitTask?.cancel()
        guard !isDragging else { return }
        isDragging = true
        if AppState.shared.isPeekOpen { AppState.shared.isPeekOpen = false }
        NotchController.shared.present(.fileDrop, for: nil)
    }

    func dragMoved(to point: CGPoint) {
        let width = NotchController.shared.sizeFor(.surface(.fileDrop)).width
        let slot = NotchDropLayout.slot(at: point, width: width, count: targets.count)
        if slot != hoverSlot { withAnimation(Theme.snappy) { hoverSlot = slot } }
    }

    func dragExited() {
        exitTask?.cancel()
        exitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self else { return }
            self.endDrag()
            if NotchController.shared.mode == .surface(.fileDrop) { NotchController.shared.dismissSurface() }
        }
    }

    private func endDrag() {
        isDragging = false
        hoverSlot = nil
    }

    /// The drop itself. `slot` nil (dropped between targets) counts as the mascot.
    func drop(_ urls: [URL], slot: Int?) {
        exitTask?.cancel()
        endDrag()
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { NotchController.shared.dismissSurface(); return }
        let s = slot ?? 0
        if s >= 1, s - 1 < targets.count {
            let agent = targets[s - 1]
            let paths = Self.copy(files, into: agent)
            guard !paths.isEmpty else {
                NotchController.shared.present(.message("Couldn't copy those into \(agent.name)'s workspace."), for: 5)
                return
            }
            AgentStore.shared.send(Self.lookPrompt(paths), to: agent.slug, display: Self.display(files), source: "notch-drop")
            Sounds.play(.agentLaunch)
            NotchController.shared.present(.message("\(agent.name) is taking a look at \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")."), for: 4)
        } else {
            pendingFiles = files
            composerDraft = ""
            NotchController.shared.present(.dropComposer, for: nil)
        }
    }

    /// The mascot's composer: the ask and the files go to Awan's voice conversation, which answers about small
    /// images itself or starts the right Awan with the files (like any other turn).
    func submitComposer() {
        let ask = composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pendingFiles.isEmpty else { return }
        let files = pendingFiles
        pendingFiles = []
        composerDraft = ""
        NotchFocus.release()
        CompanionEngine.shared.sendText(ask, attachments: files)
    }

    func closeComposer() {
        pendingFiles = []
        composerDraft = ""
        NotchFocus.release()
        NotchController.shared.dismissSurface()
    }

    static func lookPrompt(_ paths: [String]) -> String {
        "Take a look at these files: " + paths.joined(separator: ", ")
    }

    static func display(_ files: [URL]) -> String {
        files.count == 1 ? "Take a look at \(files[0].lastPathComponent)" : "Take a look at these \(files.count) files"
    }

    /// Copies (never moves) into `<workspace>/tmp/`, keeping names unique. Returns the new absolute paths.
    static func copy(_ files: [URL], into agent: AwanAgent) -> [String] {
        let tmp = Paths.ensure(agent.workspace.appendingPathComponent("tmp", isDirectory: true))
        return copy(files, to: tmp)
    }

    static func copy(_ files: [URL], to dir: URL) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for f in files {
            var dest = dir.appendingPathComponent(f.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                let base = f.deletingPathExtension().lastPathComponent, ext = f.pathExtension
                dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            if (try? fm.copyItem(at: f, to: dest)) != nil { out.append(dest.path) }
        }
        return out
    }

    /// Snapshot/demo only.
    func debugInstall(dragging: Bool, hover: Int?, files: [URL], draft: String = "") {
        isDragging = dragging
        hoverSlot = hover
        pendingFiles = files
        composerDraft = draft
    }
}

/// Geometry of the drop row (pure, shared by the view and the hit test).
enum NotchDropLayout {
    static let slotWidth: CGFloat = 78
    static let maxAwans = 6
    static let height: CGFloat = 172
    static let rowTop: CGFloat = 64
    static let rowHeight: CGFloat = 92

    static func targets(_ agents: [AwanAgent]) -> [AwanAgent] { Array(agents.prefix(maxAwans)) }

    static func size(count: Int) -> CGSize {
        CGSize(width: max(400, slotWidth * CGFloat(count + 1) + 64), height: height)
    }

    /// Which slot a point (panel coordinates, top-left origin) is over; nil outside the row.
    static func slot(at p: CGPoint, width: CGFloat, count: Int) -> Int? {
        let total = slotWidth * CGFloat(count + 1)
        let start = (width - total) / 2
        guard p.y >= rowTop - 12, p.y <= rowTop + rowHeight + 12, p.x >= start, p.x < start + total else { return nil }
        return min(count, Int((p.x - start) / slotWidth))
    }
}

/// SwiftUI drop delegate for the whole notch panel.
struct NotchDropDelegate: DropDelegate {
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            NotchDropController.shared.dragEntered()
            NotchDropController.shared.dragMoved(to: info.location)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated { NotchDropController.shared.dragMoved(to: info.location) }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { NotchDropController.shared.dragExited() }
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        let slot = MainActor.assumeIsolated {
            NotchDropLayout.slot(at: info.location, width: NotchController.shared.sizeFor(.surface(.fileDrop)).width,
                                 count: NotchDropController.shared.targets.count)
        }
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers {
                if let url = await Self.loadURL(p) { urls.append(url) }
            }
            NotchDropController.shared.drop(urls, slot: slot)
        }
        return true
    }

    private static func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = p.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }
}

// MARK: - Views

/// The widened notch while files hover: "Drop on an Awan" + the mascot and the roster as targets.
struct FileDropSurface: View {
    @ObservedObject private var drop = NotchDropController.shared
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.lime)
                Text(headline).font(.awan(13, .semibold)).foregroundStyle(Theme.text)
            }
            .frame(height: 24)
            .padding(.top, NotchDropLayout.rowTop - 30)
            .padding(.bottom, 6)
            HStack(spacing: 0) {
                slot(0, name: "Ask Awan") {
                    CloudCreature(appearance: .mascot, mood: drop.hoverSlot == 0 ? .happy : .idle, glow: false).frame(width: 40)
                }
                ForEach(Array(drop.targets.enumerated()), id: \.element.slug) { i, a in
                    slot(i + 1, name: a.name) {
                        AgentAvatar(appearance: a.character, size: 44, mood: drop.hoverSlot == i + 1 ? .happy : .idle, showRing: false)
                    }
                }
            }
            .frame(height: NotchDropLayout.rowHeight)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var headline: String {
        guard let s = drop.hoverSlot else { return "Drop on an Awan to hand these over" }
        if s == 0 { return "Drop here and tell me what to do" }
        let t = drop.targets
        return s - 1 < t.count ? "Send to \(t[s - 1].name)" : "Drop on an Awan to hand these over"
    }

    private func slot<Face: View>(_ index: Int, name: String, @ViewBuilder face: () -> Face) -> some View {
        let hot = drop.hoverSlot == index
        return VStack(spacing: 6) {
            ZStack {
                Circle().fill(hot ? Theme.lime.opacity(0.18) : Color.white.opacity(0.05)).frame(width: 56, height: 56)
                Circle().strokeBorder(hot ? Theme.lime : Theme.strokeStrong, style: StrokeStyle(lineWidth: hot ? 2 : 1, dash: hot ? [] : [3, 3]))
                    .frame(width: 56, height: 56)
                face()
            }
            .scaleEffect(hot ? 1.12 : 1)
            Text(name).font(.awan(11, hot ? .semibold : .medium)).foregroundStyle(hot ? Theme.text : Theme.textSecondary)
                .lineLimit(1).frame(width: NotchDropLayout.slotWidth - 8)
        }
        .frame(width: NotchDropLayout.slotWidth)
        .animation(Theme.snappy, value: hot)
    }
}

/// After a drop on the mascot: file chips + "What should I do with these?".
struct DropComposerSurface: View {
    @ObservedObject private var drop = NotchDropController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(drop.pendingFiles.prefix(3), id: \.self) { f in
                    HStack(spacing: 5) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 14, height: 14)
                        Text(f.lastPathComponent).font(.awan(11.5, .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 8).frame(height: 22).frame(maxWidth: 150)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                if drop.pendingFiles.count > 3 {
                    Text("+\(drop.pendingFiles.count - 3)").font(.awan(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                CloudCreature(appearance: .mascot, mood: drop.composerDraft.isEmpty ? .listening : .happy, glow: false).frame(width: 30, height: 26)
                ComposerField(text: $drop.composerDraft, placeholder: "What should I do with these?",
                              onSubmit: { drop.submitComposer() }, onCancel: { drop.closeComposer() })
                    .frame(height: 24)
                if drop.composerDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                    CircleIconButton(systemName: "xmark", size: 24, help: "Close (esc)") { drop.closeComposer() }
                } else {
                    Button { drop.submitComposer() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.textOnLime)
                            .frame(width: 24, height: 24).background(Circle().fill(Theme.lime))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.top, 34)
    }
}
