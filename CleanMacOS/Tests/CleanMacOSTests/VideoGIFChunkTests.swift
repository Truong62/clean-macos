import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CleanMacOS

struct VideoGIFChunkTests {
    @Test func combinesChunksWithoutLosingPalettesOrFrames() throws {
        let first = try chunk(red: 255, green: 0)
        let second = try chunk(red: 0, green: 255)
        let a = try VideoGIFChunk(data: first, includesLoop: true)
        let b = try VideoGIFChunk(data: second, includesLoop: false)
        let combined = a.header + a.records + b.records + Data([0x3B])
        let source = try #require(CGImageSourceCreateWithData(combined as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        let red = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let green = try #require(CGImageSourceCreateImageAtIndex(source, 1, nil))
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(red, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(context.data!.assumingMemoryBound(to: UInt8.self)[0] > 200)
        context.draw(green, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(context.data!.assumingMemoryBound(to: UInt8.self)[1] > 200)
    }

    @Test func rejectsTruncatedAndUnknownGIFRecords() throws {
        #expect(throws: (any Error).self) { try VideoGIFChunk(data: Data([0, 1]), includesLoop: true) }
        let valid = try chunk(red: 255, green: 0)
        for count in [6, 12, valid.count - 1] {
            #expect(throws: (any Error).self) { try VideoGIFChunk(data: valid.prefix(count), includesLoop: true) }
        }
    }

    @Test func waveformBinsClampAndIgnoreInvalidSamples() {
        var waveform = VideoWaveform(duration: 2, bins: 2)
        waveform.add(peak: 0.4, at: 0.1)
        waveform.add(peak: 0.2, at: 0.2)
        waveform.add(peak: 2, at: 1.5)
        waveform.add(peak: .nan, at: 0.5)
        #expect(waveform.peaks == [0.4, 1])
    }

    private func chunk(red: UInt8, green: UInt8) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: Double(red) / 255, green: Double(green) / 255, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
