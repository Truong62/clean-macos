import Foundation
import CoreGraphics

enum VideoPointerSmoothing: String, Codable, CaseIterable {
    case none, light, smooth, cinematic
    var frequency: Double? {
        switch self {
        case .none: nil
        case .light: 4
        case .smooth: 2
        case .cinematic: 1.2
        }
    }
}

enum VideoMotion {
    static func index(at time: Double, in samples: [VideoPointerSample]) -> Int? {
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if samples[mid].time <= time { lower = mid + 1 } else { upper = mid }
        }
        return lower == 0 ? nil : lower - 1
    }

    static func smoothed(_ samples: [VideoPointerSample], clicks: [Double], mode: VideoPointerSmoothing) -> [VideoPointerSample] {
        guard samples.count > 2, let frequency = mode.frequency else { return samples }
        var points = samples.map(\.point)
        for index in 1..<points.count {
            let alpha = 1 - exp(-2 * .pi * frequency * max(0, samples[index].time - samples[index - 1].time))
            points[index] = blend(points[index - 1], points[index], alpha)
        }
        for index in stride(from: points.count - 2, through: 0, by: -1) {
            let alpha = 1 - exp(-2 * .pi * frequency * max(0, samples[index + 1].time - samples[index].time))
            points[index] = blend(points[index + 1], points[index], alpha)
        }
        let orderedClicks = clicks.sorted()
        return samples.enumerated().map { index, sample in
            var lower = 0
            var upper = orderedClicks.count
            while lower < upper {
                let mid = (lower + upper) / 2
                if orderedClicks[mid] < sample.time { lower = mid + 1 } else { upper = mid }
            }
            let nearClick = (lower < orderedClicks.count && abs(orderedClicks[lower] - sample.time) <= 0.12)
                || (lower > 0 && abs(orderedClicks[lower - 1] - sample.time) <= 0.12)
            let delta = index > 0 ? hypot(sample.point.x - samples[index - 1].point.x, sample.point.y - samples[index - 1].point.y) : 0
            var copy = sample
            if !nearClick && !sample.pressed && delta < 0.08 { copy.point = points[index] }
            return copy
        }
    }

    static func opacities(_ samples: [VideoPointerSample]) -> [Double] {
        var result = Array(repeating: 1.0, count: samples.count)
        var start = 0
        while start < samples.count {
            var end = start
            let point = samples[start].point
            while end + 1 < samples.count && hypot(samples[end + 1].point.x - point.x, samples[end + 1].point.y - point.y) < 0.001 { end += 1 }
            for index in start...end {
                let still = samples[index].time - samples[start].time
                let fadeOut = 1 - min(1, max(0, (still - 2.5) / 0.4))
                let fadeIn = end + 1 < samples.count ? min(1, max(0, (samples[index].time - samples[end + 1].time + 0.25) / 0.25)) : 0
                result[index] = samples[index].visible ? max(fadeOut, fadeIn) : 0
            }
            start = end + 1
        }
        return result
    }

    static func opacity(at time: Double, samples: [VideoPointerSample]) -> Double {
        guard let index = index(at: time, in: samples), samples[index].visible else { return 0 }
        let point = samples[index].point
        var start = index
        while start > 0 && hypot(samples[start - 1].point.x - point.x, samples[start - 1].point.y - point.y) < 0.001 { start -= 1 }
        let still = time - samples[start].time
        guard still > 2.5 else { return 1 }
        var end = index
        while end + 1 < samples.count && hypot(samples[end + 1].point.x - point.x, samples[end + 1].point.y - point.y) < 0.001 { end += 1 }
        let fadeOut = 1 - min(1, (still - 2.5) / 0.4)
        let fadeIn = end + 1 < samples.count ? min(1, max(0, (time - samples[end + 1].time + 0.25) / 0.25)) : 0
        return max(fadeOut, fadeIn)
    }

    static func cluster(at time: Double, samples: [VideoPointerSample], strength: Double) -> CGPoint {
        guard let index = index(at: time, in: samples) else { return CGPoint(x: 0.5, y: 0.5) }
        var box = CGRect(origin: samples[index].point, size: .zero)
        if index > 0 {
            for previous in stride(from: index - 1, through: 0, by: -1) {
                guard time - samples[previous].time <= 0.6 else { break }
                let candidate = box.union(CGRect(origin: samples[previous].point, size: .zero))
                guard candidate.width <= 0.5 / strength, candidate.height <= 0.7 / strength else { break }
                box = candidate
            }
        }
        return CGPoint(x: box.midX, y: box.midY)
    }

    private static func blend(_ a: CGPoint, _ b: CGPoint, _ fraction: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
    }
}

struct VideoSpring {
    var value: Double
    var velocity = 0.0
    mutating func advance(to target: Double, duration: Double) {
        var remaining = min(10, max(0, duration))
        while remaining > 0 {
            let dt = min(1 / 240.0, remaining)
            let acceleration = (200 * (target - value) - 40 * velocity) / 2.25
            velocity += acceleration * dt
            value += velocity * dt
            remaining -= dt
        }
    }
}

struct VideoCameraSample {
    var scale: Double
    var origin: CGPoint
}

enum VideoCamera {
    static func build(zooms: [VideoZoom], pointer: [VideoPointerSample], duration: Double) -> [VideoCameraSample] {
        guard duration.isFinite, duration > 0 else { return [] }
        var scale = VideoSpring(value: 1)
        var x = VideoSpring(value: 0)
        var y = VideoSpring(value: 0)
        return (0...Int(ceil(duration * 60))).map { index in
            let time = Double(index) / 60
            let zoom = zooms.last { $0.span.start <= time && time <= $0.span.end + 0.65 }
            let target = zoom.map { VideoTimeline.zoomScale($0, at: time) } ?? 1
            let focus = zoom?.focus ?? VideoMotion.cluster(at: time + 0.1, samples: pointer, strength: zoom?.strength ?? 1.8)
            let targetX = min(1, max(0, (focus.x - 0.25) / 0.5)) * (1 - 1 / target)
            let targetY = min(1, max(0, ((1 - focus.y) - 0.25) / 0.5)) * (1 - 1 / target)
            scale.advance(to: target, duration: 1 / 60)
            x.advance(to: targetX, duration: 1 / 60)
            y.advance(to: targetY, duration: 1 / 60)
            return VideoCameraSample(scale: max(1, scale.value), origin: CGPoint(x: max(0, x.value), y: max(0, y.value)))
        }
    }
}
