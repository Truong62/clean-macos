import AVFoundation
import CoreImage

final class VideoInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let sourceID: CMPersistentTrackID
    let plan: VideoRenderPlan
    let transform: CGAffineTransform
    let speed: Double

    init(range: CMTimeRange, sourceID: CMPersistentTrackID, plan: VideoRenderPlan, transform: CGAffineTransform, speed: Double) {
        timeRange = range
        self.sourceID = sourceID
        requiredSourceTrackIDs = [NSNumber(value: sourceID)]
        self.plan = plan
        self.transform = transform
        self.speed = speed
    }
}

final class VideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                      kCVPixelBufferMetalCompatibilityKey as String: true]
    private let queue = DispatchQueue(label: "mackit.video.compositor", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var generation = 0

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock()
        let generation = generation
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let cancelled = generation != self.generation
            lock.unlock()
            if cancelled { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? VideoInstruction,
                  let source = request.sourceFrame(byTrackID: instruction.sourceID),
                  let buffer = request.renderContext.newPixelBuffer() else {
                request.finish(with: RecordingError.failed("Could not render a video frame."))
                return
            }
            let image = CIImage(cvPixelBuffer: source).transformed(by: instruction.transform)
            let rendered = instruction.plan.render(image, at: request.compositionTime.seconds * instruction.speed)
            context.render(rendered, to: buffer, bounds: CGRect(origin: .zero, size: instruction.plan.canvas), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            request.finish(withComposedVideoFrame: buffer)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation += 1
        lock.unlock()
    }
}
