import AppKit
import Combine
import SwiftUI

/// Docked cursor mode (Settings → Cursor → Dock cursor): instead of following the pointer, Awan
/// lives in a small pill at the top-right of the main screen. The pill's chevron expands a
/// vertical stack of agent bubbles; hovering a bubble shows that Awan's card.
/// Three separate small panels so only what's drawn takes clicks.
@MainActor
final class DockController: ObservableObject {
    @Published var expanded = false
    @Published private(set) var cardSlug: String?
    @Published private(set) var stackSlugs: [String] = []
    /// Height of the open hover card (without its shadow margin); the stack leaves this much room
    /// in the hovered portrait's slot. 0 while no card is measured.
    @Published private(set) var cardContentHeight: CGFloat = 0

    /// Called after the dock moves (the buddy's home point changes with it).
    var onLayout: (() -> Void)?

    // Measured on the reference dock:
    // a 40×18 chevron capsule 29 pt below the menu bar and 26 pt in from the right edge, 40 pt
    // portraits centred under it starting 11 pt below, 48 pt pitch; the hover card (272 wide)
    // opens in place of the hovered portrait, right-aligned with the pill, pushing the rest down.
    static let pillSize = CGSize(width: 40, height: 18)
    static let pillTopInset: CGFloat = 29
    static let pillRightInset: CGFloat = 26
    static let bubbleSize: CGFloat = 40
    static let bubbleGap: CGFloat = 8
    static let stackTopGap: CGFloat = 11
    static let stackPadding: CGFloat = 0
    /// Transparent room around each panel's content for shadows.
    static let margin: CGFloat = 24

    private var pillPanel: DockPanel?
    private var stackPanel: DockPanel?
    private var cardPanel: DockPanel?
    private var docked = false
    private var sharing = true
    private var hoveringBubble: String?
    private var hoveringCard = false
    private var engaged = false
    private var hideTask: Task<Void, Never>?
    private var stackSize = CGSize(width: 60, height: 60)
    private var cardSize = CGSize(width: 320, height: 360)
    private var cancellables = Set<AnyCancellable>()
    private var observing = false

    // MARK: Geometry

    /// The screen with the menu bar.
    private var homeScreen: NSScreen? { NSScreen.screens.first ?? NSScreen.main }

    /// Visible frame of the pill (without the shadow margin), global coords.
    var pillRect: CGRect {
        let visible = homeScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
        return CGRect(x: visible.maxX - Self.pillSize.width - Self.pillRightInset, y: visible.maxY - Self.pillSize.height - Self.pillTopInset,
                      width: Self.pillSize.width, height: Self.pillSize.height)
    }

    /// Where the docked buddy lives (flights start and end here).
    var anchor: CGPoint { CGPoint(x: pillRect.midX, y: pillRect.midY) }

    /// Centre of stack bubble `index`, global coords (portraits after the open card's slot sit below the card).
    func bubbleCenter(_ index: Int) -> CGPoint {
        let top = pillRect.minY - Self.stackTopGap
        var y = top - Self.bubbleSize / 2 - CGFloat(index) * (Self.bubbleSize + Self.bubbleGap)
        if let slug = cardSlug, let open = stackSlugs.firstIndex(of: slug), index > open, cardContentHeight > Self.bubbleSize {
            y -= cardContentHeight - Self.bubbleSize
        }
        return CGPoint(x: pillRect.midX, y: y)
    }

    /// The open card's visible rect (global), for keeping it open while the pointer is on it.
    var cardContentRect: CGRect? {
        guard let cardPanel, cardPanel.isVisible else { return nil }
        return cardPanel.frame.insetBy(dx: Self.margin, dy: Self.margin)
    }

    // MARK: Lifecycle

    /// The pill + agent stack show whenever Awans are running or have news (reference: the stack sits at the
    /// top right even while the buddy follows the pointer); docking only decides whether the buddy lives in the pill.
    func setDocked(_ on: Bool) {
        docked = on
        startObserving()
        refreshStack()
    }

    private var presenceShown = false

    /// Show or hide the pill/stack for the current mode and roster.
    private func updatePresence() {
        let show = docked || !stackSlugs.isEmpty
        if show {
            if !presenceShown && !docked { expanded = true }   // agents arriving while undocked: open the stack
            presenceShown = true
            showPill()
            if expanded { showStack() } else { stackPanel?.orderOut(nil) }
        } else {
            presenceShown = false
            for panel in [pillPanel, stackPanel, cardPanel] { panel?.orderOut(nil) }
            cardSlug = nil
            hoveringBubble = nil
            hoveringCard = false
            engaged = false
        }
    }

    func setSharing(_ show: Bool) {
        sharing = show
        for panel in [pillPanel, stackPanel, cardPanel] { panel?.sharingType = show ? .readOnly : .none }
    }

    func screensChanged() {
        guard docked || presenceShown else { return }
        layoutPill()
        layoutStack()
        layoutCard()
        onLayout?()
    }

    func toggleExpanded() {
        withAnimation(Theme.snappy) { expanded.toggle() }
        if expanded {
            refreshStack()
            showStack()
        } else {
            stackPanel?.orderOut(nil)
            hideCard()
        }
    }

    private func startObserving() {
        guard !observing else { return }
        observing = true
        AgentStore.shared.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refreshStack() }
            .store(in: &cancellables)
    }

    /// Awans with activity: running, unread, or active in the last 12 hours (max 6).
    static func activeSlugs() -> [String] {
        let store = AgentStore.shared
        let recent = Date().addingTimeInterval(-12 * 3600)
        let candidates = store.visibleAgents.filter { agent in
            let t = store.thread(agent.slug)
            return t.activeTurn != nil || t.unread || (!t.turns.isEmpty && (t.lastActivityAt ?? .distantPast) > recent)
        }
        func rank(_ a: AwanAgent) -> Int {
            let t = store.thread(a.slug)
            return t.activeTurn != nil ? 0 : t.unread ? 1 : 2
        }
        return Array(candidates.enumerated().sorted { l, r in
            rank(l.element) != rank(r.element) ? rank(l.element) < rank(r.element) : l.offset < r.offset
        }.map(\.element.slug).prefix(6))
    }

    func refreshStack() {
        let slugs = Self.activeSlugs()
        if slugs != stackSlugs { stackSlugs = slugs }
        if let card = cardSlug, !slugs.contains(card), !engaged { hideCard() }
        updatePresence()
        relayoutSoon()
    }

    /// Re-fit the stack and card panels once SwiftUI has applied the latest state.
    func relayoutSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.layoutStack()
            self?.layoutCard()
        }
    }

    /// The SwiftUI content's ideal size (content is `.fixedSize()` + shadow margin).
    private func fitted(_ panel: DockPanel?, fallback: CGSize) -> CGSize {
        guard let host = panel?.contentView else { return fallback }
        host.layoutSubtreeIfNeeded()
        let size = host.intrinsicContentSize
        return size.width > 1 && size.height > 1 ? size : fallback
    }

    // MARK: Panels

    private func makePanel(allowsKey: Bool, root: some View) -> DockPanel {
        let panel = DockPanel(allowsKey: allowsKey)
        let host = FirstMouseHostingView(rootView: AnyView(root))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.sharingType = sharing ? .readOnly : .none
        return panel
    }

    private func showPill() {
        if pillPanel == nil {
            pillPanel = makePanel(allowsKey: false, root: DockPillView(dock: self).padding(Self.margin))
        }
        layoutPill()
        pillPanel?.orderFrontRegardless()
        onLayout?()
    }

    private func layoutPill() {
        pillPanel?.setFrame(pillRect.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
    }

    private func showStack() {
        guard docked || !stackSlugs.isEmpty else { return }
        if stackPanel == nil {
            stackPanel = makePanel(allowsKey: false, root: DockStackView(dock: self)
                .padding(Self.margin)
                .fixedSize()
                .reportSize { [weak self] in self?.stackSizeChanged($0) })
        }
        layoutStack()
        stackPanel?.orderFrontRegardless()
    }

    private func stackSizeChanged(_ size: CGSize) {
        guard size != stackSize, size.width > 0 else { return }
        stackSize = size
        // Use the reported size as is: the hosting view's intrinsic size lags a frame when the
        // stack shrinks (the card closing), and re-fitting here would keep the old, taller frame.
        layoutStack(fit: false)
    }

    private func layoutStack(fit: Bool = true) {
        guard let stackPanel else { return }
        if fit { stackSize = fitted(stackPanel, fallback: stackSize) }
        let m = Self.margin
        let frame = CGRect(x: pillRect.midX - stackSize.width / 2, y: pillRect.minY - Self.stackTopGap + m - stackSize.height,
                           width: stackSize.width, height: stackSize.height)
        stackPanel.setFrame(frame, display: true)
    }

    // MARK: Hover card

    /// A card closed with ×. Its portrait sits right under the ×, so the pointer is on it the moment the card goes
    /// away; that hover must not reopen the card until the pointer has left the portrait once.
    private var dismissedSlug: String?

    /// The card's × (and Esc): close it and keep it closed while the pointer stays where it was.
    func closeCard() {
        dismissedSlug = cardSlug
        hoveringBubble = nil
        hoveringCard = false
        hideCard()
    }

    func bubbleHover(_ slug: String, _ inside: Bool) {
        if inside, slug != dismissedSlug { dismissedSlug = nil }
        if inside, slug == dismissedSlug { return }
        if !inside, slug == dismissedSlug { dismissedSlug = nil }
        if inside {
            hoveringBubble = slug
        } else if hoveringBubble == slug {
            hoveringBubble = nil
        }
        updateHover()
    }

    func cardHover(_ inside: Bool) {
        hoveringCard = inside
        updateHover()
    }

    func setEngaged(_ on: Bool) {
        engaged = on
        updateHover()
    }

    private func updateHover() {
        if let slug = hoveringBubble, !(engaged && cardSlug != nil && cardSlug != slug) {
            hideTask?.cancel()
            showCard(slug)
        } else if hoveringCard || engaged {
            hideTask?.cancel()
        } else if cardSlug != nil {
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self else { return }
                // The card covers the portrait it grew from, so the portrait's hover ends as the card
                // appears; if the pointer is resting on the card, keep it (no hide/show flicker).
                if let rect = self.cardContentRect, rect.contains(NSEvent.mouseLocation) {
                    self.hoveringCard = true
                    return
                }
                self.hideCard()
            }
        }
    }

    func showCard(_ slug: String) {
        guard docked || !stackSlugs.isEmpty else { return }
        if cardPanel == nil {
            cardPanel = makePanel(allowsKey: true, root: DockCardRoot(dock: self)
                .reportSize { [weak self] in self?.cardSizeChanged($0) })
        }
        if cardSlug != slug {
            cardSlug = slug
            AgentStore.shared.markRead(slug)
        }
        layoutCard()
        cardPanel?.orderFrontRegardless()
        relayoutSoon()
    }

    /// The dock's on-screen panels, back to front (live snapshot capture).
    var visiblePanels: [NSPanel] { [pillPanel, stackPanel, cardPanel].compactMap { $0 }.filter(\.isVisible) }

    /// Snapshots only: mark a bubble as hovered without opening panels.
    func setPreviewCard(_ slug: String?, contentHeight: CGFloat = 0) {
        cardSlug = slug
        cardContentHeight = slug == nil ? 0 : contentHeight
    }

    func hideCard() {
        hideTask?.cancel()
        cardSlug = nil
        engaged = false
        cardPanel?.orderOut(nil)
        if cardContentHeight != 0 { cardContentHeight = 0 }
        relayoutSoon()   // the portraits below close back up
    }

    private func cardSizeChanged(_ size: CGSize) {
        guard size != cardSize, size.width > 0 else { return }
        cardSize = size
        layoutCard()
    }

    /// The card grows out of the hovered portrait: its top edge is the portrait's top, its right
    /// edge the pill's; the portraits below it move down (see `bubbleCenter`).
    private func layoutCard() {
        guard let cardPanel, let slug = cardSlug else { return }
        cardSize = fitted(cardPanel, fallback: cardSize)
        let m = Self.margin
        let h = max(0, cardSize.height - 2 * m)
        if abs(h - cardContentHeight) > 0.5 {
            cardContentHeight = h
            DispatchQueue.main.async { [weak self] in self?.layoutStack() }   // make room below the card
        }
        let visible = homeScreen?.visibleFrame ?? .zero
        let index = stackSlugs.firstIndex(of: slug) ?? 0
        let bubble = bubbleCenter(index)
        let contentH = cardSize.height - 2 * m
        var top = bubble.y + Self.bubbleSize / 2
        top = min(top, visible.maxY - 6)
        top = max(top, visible.minY + 6 + contentH)
        let right = pillRect.maxX
        let frame = CGRect(x: right + m - cardSize.width, y: top + m - cardSize.height, width: cardSize.width, height: cardSize.height)
        cardPanel.setFrame(frame, display: true)
    }
}

// MARK: - Size reporting

private struct ReportedSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

extension View {
    /// Reports this view's laid-out size (panels resize to fit their SwiftUI content).
    func reportSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: ReportedSizeKey.self, value: g.size) })
            .onPreferenceChange(ReportedSizeKey.self) { size in
                MainActor.assumeIsolated { onChange(size) }
            }
    }
}
