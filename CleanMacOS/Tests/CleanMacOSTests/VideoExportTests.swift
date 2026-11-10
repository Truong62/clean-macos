import AVFoundation
import ImageIO
import Testing
@testable import CleanMacOS

struct VideoExportTests {
    @Test func exportsCutMovieAndGIFWithoutCapturingTheScreen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("video-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("master.mov")
        try await fixture(source)
        var document = VideoEditDocument(trim: VideoSpan(start: 0, end: 2))
        document.cuts = [VideoSpan(start: 0.5, end: 1)]
        document.speed = 2
        document.look = .studio
        document.margin = 0.45
        document.corners = 0.35
        document.background = .gradient
        document.overlays = [VideoOverlay(kind: .blur, span: VideoSpan(start: 0, end: 2))]
        document.zooms = [VideoZoom(span: VideoSpan(start: 0, end: 1))]
        let movie = folder.appendingPathComponent("export.mp4")
        try await VideoExport.run(master: source, document: document, tracks: VideoTracks(), destination: movie) { _ in }
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 0.75) < 0.12)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        document.format = .gif
        document.gifFPS = 8
        let gif = folder.appendingPathComponent("export.gif")
        try await VideoExport.run(master: source, document: document, tracks: VideoTracks(), destination: gif) { _ in }
        let image = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(image) == 6)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.allSatisfy { !$0.hasPrefix(".") })
    }

    @Test func cancelledExportKeepsAnExistingDestination() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("video-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let master = folder.appendingPathComponent("master.mov")
        try await fixture(master)
        let destination = folder.appendingPathComponent("existing.mp4")
        let original = Data("existing file".utf8)
        try original.write(to: destination)
        let task = Task {
            try await VideoExport.run(master: master, document: VideoEditDocument(trim: VideoSpan(start: 0, end: 2)), tracks: VideoTracks(), destination: destination) { _ in }
        }
        task.cancel()
        _ = try? await task.value
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix(".") })
    }

    private func fixture(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var pixel: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel) == kCVReturnSuccess)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, frame < 10 ? 40 : 180, CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
