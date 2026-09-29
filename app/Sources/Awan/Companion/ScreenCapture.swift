// Adapted from farzaa/clicky (MIT) — CompanionScreenCaptureUtility: every display, cursor screen first, own windows excluded.
import AppKit
import ScreenCaptureKit

/// One captured display plus what's needed to map the model's pixel coordinates back to the screen.
struct ScreenCaptureFrame {
    /// 1-based, cursor screen first (matches the "screen N of M" label the model sees).
    var index: Int
    var count: Int
    var isCursorScreen: Bool
    var displayID: CGDirectDisplayID
    var geometry: CaptureGeometry
    var image: CGImage
    var jpeg: Data
    var label: String

    /// Body entry for POST /v1/companion/respond.
    var requestImage: [String: String] { ["data": jpeg.base64EncodedString(), "label": label, "mime": "image/jpeg"] }
}

enum ScreenCaptureError: LocalizedError {
    case noDisplays, permissionDenied(String)
    var errorDescription: String? {
        switch self {
        case .noDisplays: return "No display available to capture."
        case let .permissionDenied(m): return "Awan can't see your screen yet (Screen Recording permission). \(m)"
        }
    }
}

enum ScreenCapture {
    static let maxDimension = 1280

    /// Screen Recording permission (no prompt).
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// The model-facing label, e.g. "screen 1 of 2 — primary focus (cursor is here) (image dimensions: 1280x800 pixels)".
    static func label(index: Int, count: Int, isCursorScreen: Bool, width: Int, height: Int) -> String {
        let role = isCursorScreen ? "primary focus (cursor is here)" : "secondary screen"
        return "screen \(index) of \(count) — \(role) (image dimensions: \(width)x\(height) pixels)"
    }

    /// Captures every display as JPEG (longest side 1280), excluding Awan's own windows.
    @MainActor
    static func captureAll(maxDimension: Int = maxDimension) async throws -> [ScreenCaptureFrame] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError.permissionDenied(error.localizedDescription)
        }
        guard !content.displays.isEmpty else { throw ScreenCaptureError.noDisplays }

        let mouse = NSEvent.mouseLocation
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }

        // SCDisplay.frame is top-left based; NSScreen.frame is AppKit global (bottom-left) like NSEvent.mouseLocation.
        var screens: [CGDirectDisplayID: NSScreen] = [:]
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID { screens[n] = s }
        }
        func frame(_ d: SCDisplay) -> CGRect {
            screens[d.displayID]?.frame ?? CGRect(x: d.frame.minX, y: d.frame.minY, width: CGFloat(d.width), height: CGFloat(d.height))
        }
        var displays = content.displays
        let cursorIdx = displays.firstIndex { frame($0).contains(mouse) } ?? displays.firstIndex { $0.displayID == CGMainDisplayID() } ?? 0
        let cursorDisplay = displays.remove(at: cursorIdx)
        displays.insert(cursorDisplay, at: 0)

        var frames: [ScreenCaptureFrame] = []
        for (i, display) in displays.enumerated() {
            let displayFrame = frame(display)
            let config = SCStreamConfiguration()
            let aspect = CGFloat(display.width) / CGFloat(max(1, display.height))
            if display.width >= display.height {
                config.width = maxDimension
                config.height = Int((CGFloat(maxDimension) / aspect).rounded())
            } else {
                config.height = maxDimension
                config.width = Int((CGFloat(maxDimension) * aspect).rounded())
            }
            config.showsCursor = true
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                if frames.isEmpty && i == displays.count - 1 { throw ScreenCaptureError.permissionDenied(error.localizedDescription) }
                continue
            }
            guard let jpeg = jpegData(image) else { continue }
            frames.append(ScreenCaptureFrame(
                index: i + 1, count: displays.count, isCursorScreen: i == 0, displayID: display.displayID,
                geometry: CaptureGeometry(displayFrame: displayFrame, pixelSize: CGSize(width: image.width, height: image.height)),
                image: image, jpeg: jpeg, label: ""
            ))
        }
        guard !frames.isEmpty else { throw ScreenCaptureError.noDisplays }
        // Re-number in case a display failed, then label.
        for i in frames.indices {
            frames[i].index = i + 1
            frames[i].count = frames.count
            frames[i].label = label(index: i + 1, count: frames.count, isCursorScreen: frames[i].isCursorScreen, width: frames[i].image.width, height: frames[i].image.height)
        }
        return frames
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.8) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Paints the user's spatial trail (global points) onto a capture as a translucent Signal Lime stroke.
    static func drawTrail(_ trail: [CGPoint], on frame: ScreenCaptureFrame) -> ScreenCaptureFrame {
        guard trail.count >= 2 else { return frame }
        let w = frame.image.width, h = frame.image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return frame }
        ctx.draw(frame.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext is bottom-left; pixel space is top-left.
        let pts = trail.map { g -> CGPoint in
            let p = frame.geometry.pixelPoint(fromGlobal: g)
            return CGPoint(x: p.x, y: CGFloat(h) - p.y)
        }
        ctx.setStrokeColor(CGColor(red: 0xD9 / 255, green: 1, blue: 0x43 / 255, alpha: 0.62))
        ctx.setLineWidth(max(5, CGFloat(w) / 200))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addLines(between: pts)
        ctx.strokePath()
        guard let out = ctx.makeImage(), let jpeg = jpegData(out) else { return frame }
        var copy = frame
        copy.image = out
        copy.jpeg = jpeg
        return copy
    }

    /// Whether a trail is a deliberate mark (circle/scribble), not a twitch of the mouse.
    static func isMeaningfulTrail(_ trail: [CGPoint]) -> Bool {
        guard trail.count >= 6 else { return false }
        var length: CGFloat = 0
        for i in 1 ..< trail.count { length += hypot(trail[i].x - trail[i - 1].x, trail[i].y - trail[i - 1].y) }
        return length > 60
    }
}
