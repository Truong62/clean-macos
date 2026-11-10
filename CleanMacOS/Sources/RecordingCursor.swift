import AppKit
import CryptoKit

struct VideoCursorShape: Codable, Equatable {
    var png: Data
    var pointSize: CGSize
    var hotSpot: CGPoint
}

@MainActor
final class RecordingCursorReader {
    typealias Seed = @convention(c) () -> Int32
    typealias Connection = @convention(c) () -> UInt32
    typealias Scale = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private static let framework = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
    private static let seed = PrivateSymbols.load("CGSCurrentCursorSeed", from: framework, as: Seed.self)
    private static let connection = PrivateSymbols.load("CGSMainConnectionID", from: framework, as: Connection.self)
    private static let scale = PrivateSymbols.load("CGSGetCursorScale", from: framework, as: Scale.self)
    private var previousSeed: Int32?
    private(set) var identity: String?

    func read() -> (identity: String?, shape: VideoCursorShape?, scale: Double) {
        var scale: Float = 1
        if let connection = Self.connection, let read = Self.scale { _ = read(connection(), &scale) }
        let safeScale = scale.isFinite && scale > 0 ? Double(scale) : 1
        let seed = Self.seed?()
        if let seed, seed == previousSeed { return (identity, nil, safeScale) }
        previousSeed = seed
        guard let cursor = NSCursor.currentSystem, let image = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = CaptureImages.png(image, scale: 1) else { return (identity, nil, safeScale) }
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        guard hash != identity else { return (identity, nil, safeScale) }
        identity = hash
        return (hash, VideoCursorShape(png: png, pointSize: cursor.image.size, hotSpot: cursor.hotSpot), safeScale)
    }
}
