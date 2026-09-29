import SwiftUI
import AppKit
import PDFKit
import QuickLookUI

/// Side panel that previews a PDF, image, Markdown file (or anything QuickLook can show)
/// without leaving the conversation.
struct ArtifactPreviewPanel: View {
    let artifact: Artifact
    let close: () -> Void

    static func canPreview(_ a: Artifact) -> Bool {
        guard !a.path.hasPrefix("http") else { return false }
        switch a.kind {
        case .pdf, .image, .markdown, .document, .code, .spreadsheet: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                CircleIconButton(systemName: "xmark", size: 26, help: "Close preview", action: close)
                VStack(alignment: .leading, spacing: 1) {
                    Text(artifact.name).font(.awan(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Text(artifact.kind.label).font(.awan(11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 6)
                Button { NSWorkspace.shared.activateFileViewerSelecting([artifact.url]) } label: {
                    Image(systemName: "folder").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.gel(.dark, height: 26, padding: 10, fontSize: 12))
                .help("Reveal in Finder")
                Button("Open") { NSWorkspace.shared.open(artifact.url) }
                    .buttonStyle(.gel(.bone, height: 26, padding: 12, fontSize: 12))
            }
            .padding(.horizontal, 12)
            .padding(.top, 58)
            .padding(.bottom, 10)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.sidebar)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.stroke).frame(width: 1) }
    }

    @ViewBuilder private var content: some View {
        switch artifact.kind {
        case .pdf:
            PDFPreview(url: artifact.url)
        case .image:
            if let img = NSImage(contentsOf: artifact.url) {
                ScrollView { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(14) }
            } else { unavailable }
        case .markdown:
            if let text = try? String(contentsOf: artifact.url, encoding: .utf8) {
                ScrollView { MarkdownText(source: text, fontSize: 13).padding(16) }
            } else { unavailable }
        default:
            QuickLookPreview(url: artifact.url)
        }
    }

    private var unavailable: some View {
        Text("This document couldn’t be loaded.").font(.awan(13)).foregroundStyle(Theme.textTertiary)
    }
}

struct PDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = NSColor(hex: 0x1B1B19)
        v.document = PDFDocument(url: url)
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
    }
}

struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .compact)!
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ v: QLPreviewView, coordinator: ()) { v.close() }
}
