import AppKit
import ScreenCaptureKit

/// Window screenshots through ScreenCaptureKit (one window only, never the whole display).
enum CUCapture {
    struct Shot {
        let image: CGImage
        /// Window size in points, and image pixels per point (what pixel-click coordinates are divided by).
        let pointSize: CGSize
        let scale: CGFloat
    }

    private final class Box: @unchecked Sendable { var shot: Shot?; var error: String? }

    /// Captures one window, downscaled so its longest edge is at most `maxLongEdge` pixels. Blocks the calling
    /// (non-main) thread for at most `timeout` seconds.
    static func window(_ windowID: CGWindowID, maxLongEdge: Int, timeout: TimeInterval = 8) -> Result<Shot, CUError> {
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let win = content.windows.first(where: { $0.windowID == windowID }) else {
                    box.error = "window \(windowID) isn't capturable (closed, or on another Space)"
                    sem.signal(); return
                }
                let pts = win.frame.size
                let backing = CUCapture.displays().map(\.scale).max() ?? 2
                var scale = backing
                let longEdge = max(pts.width, pts.height) * scale
                if longEdge > CGFloat(maxLongEdge) { scale *= CGFloat(maxLongEdge) / longEdge }
                let cfg = SCStreamConfiguration()
                cfg.width = max(1, Int((pts.width * scale).rounded()))
                cfg.height = max(1, Int((pts.height * scale).rounded()))
                cfg.showsCursor = false
                cfg.ignoreShadowsSingleWindow = true
                cfg.captureResolution = .best
                let filter = SCContentFilter(desktopIndependentWindow: win)
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                box.shot = Shot(image: img, pointSize: pts, scale: CGFloat(img.width) / max(pts.width, 1))
            } catch {
                box.error = "screen capture failed: \(error.localizedDescription) — Screen Recording may not be granted to Awan"
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return .failure(.message("screen capture timed out")) }
        if let s = box.shot { return .success(s) }
        return .failure(.message(box.error ?? "screen capture failed"))
    }

    struct Display { let id: CGDirectDisplayID; let bounds: CGRect; let scale: CGFloat; let main: Bool }

    /// Active displays via CoreGraphics (thread-safe, unlike NSScreen).
    static func displays() -> [Display] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { id in
            let b = CGDisplayBounds(id)
            let px = CGDisplayCopyDisplayMode(id).map { CGFloat($0.pixelWidth) } ?? b.width
            return Display(id: id, bounds: b, scale: b.width > 0 ? (px / b.width).rounded() : 1, main: CGDisplayIsMain(id) != 0)
        }
    }

    static func encode(_ img: CGImage, jpeg: Bool) -> Data? {
        let rep = NSBitmapImageRep(cgImage: img)
        return jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
                    : rep.representation(using: .png, properties: [:])
    }
}
