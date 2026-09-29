import AppKit
import QuickLookThumbnailing

/// QuickLook thumbnails with an in-memory cache.
actor Thumbnails {
    static let shared = Thumbnails()
    private var cache: [String: NSImage] = [:]

    func thumbnail(for artifact: Artifact, side: CGFloat) async -> NSImage? {
        // Key includes the modification date so an edited file never shows its old thumbnail.
        let mtime = (try? FileManager.default.attributesOfItem(atPath: artifact.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(artifact.path)#\(Int(side))#\(Int(mtime))"
        if let hit = cache[key] { return hit }
        guard !artifact.path.hasPrefix("http"), FileManager.default.fileExists(atPath: artifact.path) else { return nil }
        let req = QLThumbnailGenerator.Request(fileAt: artifact.url, size: CGSize(width: side, height: side), scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        let img = rep.nsImage
        cache[key] = img
        return img
    }
}
