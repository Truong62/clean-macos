import AVFoundation
import VideoToolbox

private final class RecordingCodecProbe {
    var succeeded = false
}

enum RecordingCodec {
    static func supportsHEVC(size: CGSize) -> Bool {
        guard size.width >= 2, size.height >= 2, size.width <= 16384, size.height <= 16384 else { return false }
        let probe = RecordingCodecProbe()
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            compressedDataAllocator: nil, outputCallback: { reference, _, status, _, sample in
                guard let reference else { return }
                Unmanaged<RecordingCodecProbe>.fromOpaque(reference).takeUnretainedValue().succeeded = status == noErr && sample != nil
            }, refcon: Unmanaged.passUnretained(probe).toOpaque(), compressionSessionOut: &session)
        guard status == noErr, let session else { return false }
        defer { VTCompressionSessionInvalidate(session) }
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { return false }
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, let pixel else { return false }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) { memset(base, 0, CVPixelBufferGetDataSize(pixel)) }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        guard VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: .zero, duration: CMTime(value: 1, timescale: 60),
            frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil) == noErr,
              VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) == noErr else { return false }
        return probe.succeeded
    }

    static func settings(size: CGSize, fps: Int, bits: Double = 0.09, keyframes: Double = 2) -> [String: Any] {
        let hevc = supportsHEVC(size: size)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate(size: size, fps: fps, bits: bits),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalDurationKey: keyframes,
            AVVideoAllowFrameReorderingKey: false
        ]
        if !hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        return [AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : .h264,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height), AVVideoCompressionPropertiesKey: compression,
                AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
    }

    static func bitRate(size: CGSize, fps: Int, bits: Double) -> Int {
        Int(min(60_000_000, max(800_000, size.width * size.height * Double(max(1, fps)) * bits)))
    }
}
