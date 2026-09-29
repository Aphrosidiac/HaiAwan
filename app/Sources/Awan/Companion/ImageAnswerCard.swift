import AppKit
import SwiftUI

/// `[IMAGES:query]` → a dark response card just below the notch: a horizontal strip of photos with
/// captions; clicking one opens its source page. The images come from GET /v1/images (every one checked
/// server-side to really be an image); if none come back, no card is shown.
struct ImageAnswer: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var imageURL: URL
    var pageURL: URL?
    var thumbnailURL: URL?
    var image: NSImage?

    static func == (a: ImageAnswer, b: ImageAnswer) -> Bool { a.id == b.id && a.image === b.image }
}

@MainActor
final class ImageAnswerModel: ObservableObject {
    @Published var query = ""
    @Published var items: [ImageAnswer] = []
}

@MainActor
final class ImageAnswerCard {
    static let shared = ImageAnswerCard()
    static let size = CGSize(width: 560, height: 196)
    static let lifetime: Double = 22

    let model = ImageAnswerModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var hovering = false

    private struct Response: Decodable {
        struct Item: Decodable { var title: String; var imageUrl: String; var pageUrl: String?; var thumbnailUrl: String? }
        var images: [Item]
    }

    /// Fetch the pictures for a query and show the card once at least one thumbnail has loaded.
    func show(query: String) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            var comps = URLComponents(url: APIClient.shared.baseURL.appendingPathComponent("v1/images"), resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "q", value: query)]
            guard let url = comps?.url else { return }
            var req = URLRequest(url: url, timeoutInterval: 25)
            if let token = APIClient.shared.token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                try APIClient.shared.check(resp, data)
                let r = try JSONDecoder().decode(Response.self, from: data)
                let answers = r.images.compactMap { i -> ImageAnswer? in
                    guard let u = URL(string: i.imageUrl) else { return nil }
                    return ImageAnswer(title: i.title, imageURL: u, pageURL: i.pageUrl.flatMap(URL.init(string:)), thumbnailURL: i.thumbnailUrl.flatMap(URL.init(string:)))
                }
                guard !Task.isCancelled, !answers.isEmpty else {
                    Log.info("images: nothing for \"\(query)\" — no card")
                    return
                }
                let loaded = await Self.loadThumbnails(answers)
                guard !Task.isCancelled, !loaded.isEmpty else { return }
                self.present(query: query, items: loaded)
            } catch {
                Log.error("images: \(error.localizedDescription)")
            }
        }
    }

    /// Downloads the thumbnails in parallel; drops any that don't decode.
    static func loadThumbnails(_ items: [ImageAnswer]) async -> [ImageAnswer] {
        await withTaskGroup(of: (Int, NSImage?).self) { group in
            for (i, item) in items.enumerated() {
                group.addTask {
                    var req = URLRequest(url: item.thumbnailURL ?? item.imageURL, timeoutInterval: 10)
                    req.setValue("Awan/1.0 (FF Dev Studio)", forHTTPHeaderField: "User-Agent")
                    guard let (data, _) = try? await URLSession.shared.data(for: req), data.count < 25_000_000 else { return (i, nil) }
                    return (i, NSImage(data: data))
                }
            }
            var out = items
            for await (i, image) in group { out[i].image = image }
            return out.filter { $0.image != nil }
        }
    }

    func present(query: String, items: [ImageAnswer]) {
        model.query = query
        model.items = items
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.sharingType = Prefs.shared.showInScreenRecordings ? .readOnly : .none
        panel.setFrame(frame(), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.22; panel.animator().alphaValue = 1 }
        Sounds.play(.reveal, volume: 0.3)
        scheduleHide(Self.lifetime)
    }

    func dismiss() {
        hideTask?.cancel()
        loadTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    func setHovering(_ on: Bool) {
        hovering = on
        if on { hideTask?.cancel() } else { scheduleHide(6) }
    }

    func open(_ item: ImageAnswer) {
        NSWorkspace.shared.open(item.pageURL ?? item.imageURL)
        dismiss()
    }

    private func scheduleHide(_ seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.hovering else { return }
            self.dismiss()
        }
    }

    /// Centred under the notch and whatever notch card is open.
    private func frame() -> NSRect {
        let g = NotchGeometry.current()
        let notch = NotchController.shared
        let below = max(g.menuBarHeight, notch.sizeFor(notch.mode).height)
        let s = Self.size
        return NSRect(x: g.screenFrame.midX - s.width / 2, y: g.screenFrame.maxY - below - 10 - s.height, width: s.width, height: s.height)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar + 1
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ImageAnswerCardView(model: model, onOpen: { [weak self] in self?.open($0) },
                                                               onClose: { [weak self] in self?.dismiss() },
                                                               onHover: { [weak self] in self?.setHovering($0) }))
        host.frame = p.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }
}

struct ImageAnswerCardView: View {
    @ObservedObject var model: ImageAnswerModel
    var onOpen: (ImageAnswer) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(model.query)
                    .font(.awan(12.5, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("\(model.items.count) photo\(model.items.count == 1 ? "" : "s")")
                    .font(.awan(11.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                CircleIconButton(systemName: "xmark", size: 22, help: "Close", action: onClose)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.items) { item in
                        ImageAnswerTile(item: item) { onOpen(item) }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.panel.opacity(0.98)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(6)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        .onHover(perform: onHover)
    }
}

struct ImageAnswerTile: View {
    let item: ImageAnswer
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Theme.card
                    if let image = item.image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: 128, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(hovering ? Theme.bone.opacity(0.6) : Theme.stroke, lineWidth: 1))
                Text(item.title.isEmpty ? (item.pageURL?.host ?? item.imageURL.host ?? "") : item.title)
                    .font(.awan(11))
                    .foregroundStyle(hovering ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 128, alignment: .leading)
                Text(item.pageURL?.host?.replacingOccurrences(of: "www.", with: "") ?? item.imageURL.host ?? "")
                    .font(.awan(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .frame(width: 128, alignment: .leading)
            }
            .scaleEffect(hovering ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Theme.snappy) { hovering = h } }
        .help(item.pageURL?.absoluteString ?? item.imageURL.absoluteString)
    }
}
