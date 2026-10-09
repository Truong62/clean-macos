import AppKit
import QuickLookThumbnailing
import SwiftUI

@MainActor
final class FileThumbnailCache {
    static let shared = FileThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    func thumbnail(for path: String, side: CGFloat) async -> NSImage? {
        let key = "\(side)|\(path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path),
                                                   size: CGSize(width: side, height: side),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct FileThumbnail: View {
    let path: String
    var side: CGFloat = 32
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .task(id: path) { thumbnail = await FileThumbnailCache.shared.thumbnail(for: path, side: side) }
    }
}

enum QuickLook {
    static func preview(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
