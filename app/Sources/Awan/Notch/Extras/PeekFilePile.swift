import AppKit
import SwiftUI

/// The quick peek's file pile (reference: NotchAgentPeekFilePile / NotchAgentPeekFileTile, v1.0.52):
/// an Awan's three newest files as portrait cards (≈30×36, white rim), the newest on top tilted ≈4° clockwise and
/// right-aligned under the time's right edge; hover fans them out, click opens one, and each can be dragged
/// straight out of the notch into Finder, Mail, a chat…
struct PeekFilePile: View {
    let files: [Artifact]
    @Local private var spread = false

    static let card = CGSize(width: 30, height: 36)
    /// The newest card's (unrotated) right edge sits at x = 452 − 34.5 = 417.5 in the peek.
    static let rightInset: CGFloat = 34.5

    var body: some View {
        let pile = Array(files.prefix(3))
        ZStack(alignment: .trailing) {
            // oldest at the back, newest on top
            ForEach(Array(pile.enumerated().reversed()), id: \.element.id) { i, a in
                PeekFileTile(artifact: a)
                    .rotationEffect(.degrees(Self.angle(index: i, spread: spread)))
                    .offset(x: Self.offset(index: i, spread: spread))
                    .zIndex(Double(pile.count - i))
            }
        }
        .frame(width: Self.card.width + (spread ? 44 : 10), height: Self.card.height + 8, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Theme.snappy) { spread = h } }
    }

    /// Newest (index 0) tilted 4° clockwise; the ones behind lean the other way, then back.
    static func angle(index: Int, spread: Bool) -> Double {
        switch index {
        case 0: return 4
        case 1: return spread ? -2 : -4
        default: return spread ? 3 : 9
        }
    }

    static func offset(index: Int, spread: Bool) -> CGFloat {
        spread ? -CGFloat(index) * 22 : -CGFloat(index) * 4
    }
}

/// One portrait file card: radius 6, white 1.5 pt rim, soft shadow; the QuickLook thumbnail where possible.
struct PeekFileCard: View {
    let artifact: Artifact
    @Local private var image: NSImage? = nil

    var body: some View {
        let s = PeekFilePile.card
        ZStack {
            Color.white
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: s.width, height: s.height, alignment: .top)
            } else {
                Image(systemName: ArtifactThumb.icon(for: artifact.kind)).font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.55))
            }
        }
        .frame(width: s.width, height: s.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.32), radius: 3, y: 1.5)
        .task(id: artifact.path) { image = await Thumbnails.shared.thumbnail(for: artifact, side: 108) }
    }
}

/// One file: card, drag source (the real file URL), click to open, right-click for more.
struct PeekFileTile: View {
    let artifact: Artifact

    var body: some View {
        PeekFileCard(artifact: artifact)
            .help(artifact.name)
            .onTapGesture { NSWorkspace.shared.open(artifact.url) }
            .onDrag { Self.provider(for: artifact) }
            .contextMenu {
                Button("Open") { NSWorkspace.shared.open(artifact.url) }
                if artifact.url.isFileURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([artifact.url]) }
                }
                Button("Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.writeObjects([artifact.url as NSURL])
                }
            }
    }

    /// File artifacts drag as the file itself; web links as the URL.
    static func provider(for a: Artifact) -> NSItemProvider {
        if a.url.isFileURL {
            let p = NSItemProvider(contentsOf: a.url) ?? NSItemProvider(object: a.url as NSURL)
            p.suggestedName = a.name
            return p
        }
        return NSItemProvider(object: a.url as NSURL)
    }
}
