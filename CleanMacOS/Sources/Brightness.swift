import CoreGraphics
import Foundation

struct DDCReading: Equatable {
    let current: UInt16
    let maximum: UInt16

    var level: Double { Double(current) / Double(maximum == 0 ? DDC.defaultMaximum : maximum) }
}

enum DDC {
    static let chipAddress: UInt32 = 0x37
    static let dataAddress: UInt32 = 0x51
    static let destination: UInt8 = 0x6E
    static let replySeed: UInt8 = 0x50
    static let brightness: UInt8 = 0x10
    static let volume: UInt8 = 0x62
    static let mute: UInt8 = 0x8D
    static let setOpcode: UInt8 = 0x03
    static let getOpcode: UInt8 = 0x01
    static let replyOpcode: UInt8 = 0x02
    static let replyLength = 11
    static let defaultMaximum: UInt16 = 100

    static func setPacket(code: UInt8, value: UInt16) -> [UInt8] {
        packet([setOpcode, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    static func getPacket(code: UInt8) -> [UInt8] {
        packet([getOpcode, code])
    }

    static func parseReply(_ reply: [UInt8], code: UInt8) -> DDCReading? {
        guard reply.count >= replyLength, reply[0..<10].reduce(replySeed, ^) == reply[10],
              reply[2] == replyOpcode, reply[3] == 0, reply[4] == code else { return nil }
        return DDCReading(current: UInt16(reply[8]) << 8 | UInt16(reply[9]), maximum: UInt16(reply[6]) << 8 | UInt16(reply[7]))
    }

    static func value(for level: Double, maximum: UInt16) -> UInt16 {
        let top = Double(maximum == 0 ? defaultMaximum : maximum)
        return UInt16((min(max(level, 0), 1) * top).rounded())
    }

    private static func packet(_ payload: [UInt8]) -> [UInt8] {
        let body = [0x80 | UInt8(payload.count)] + payload
        return body + [body.reduce(destination ^ UInt8(dataAddress), ^)]
    }
}

enum LevelStep: String, Codable, CaseIterable, Identifiable {
    case standard, half, quarter

    static let gridTolerance = 0.001

    var id: String { rawValue }

    var size: Double {
        switch self {
        case .standard: 1.0 / 16
        case .half: 1.0 / 32
        case .quarter: 1.0 / 64
        }
    }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .half: "Half steps"
        case .quarter: "Quarter steps"
        }
    }

    func next(from level: Double, up: Bool) -> Double {
        let position = level / size
        let nearest = position.rounded()
        let isOnGrid = abs(position - nearest) < Self.gridTolerance
        let index = up ? (isOnGrid ? nearest + 1 : position.rounded(.up)) : (isOnGrid ? nearest - 1 : position.rounded(.down))
        return min(max(index * size, 0), 1)
    }
}

struct BrightnessSplit: Equatable {
    static let extraRange = 0.25

    let hardware: Double
    let picture: Double

    init(hardware: Double, picture: Double) {
        self.hardware = hardware
        self.picture = picture
    }

    static func level(hardware: Double, extraDimming: Bool) -> Double {
        extraDimming ? extraRange + hardware * (1 - extraRange) : hardware
    }

    init(level: Double, extraDimming: Bool) {
        guard extraDimming else {
            self.init(hardware: level, picture: 1)
            return
        }
        if level < Self.extraRange {
            self.init(hardware: 0, picture: level / Self.extraRange)
        } else {
            self.init(hardware: (level - Self.extraRange) / (1 - Self.extraRange), picture: 1)
        }
    }
}

struct GammaTable: Equatable {
    static let fullThreshold = 0.999

    var red: [Float]
    var green: [Float]
    var blue: [Float]

    func scaled(by factor: Double) -> GammaTable {
        guard factor < Self.fullThreshold else { return self }
        let gain = Float(max(factor, 0))
        return GammaTable(red: red.map { $0 * gain }, green: green.map { $0 * gain }, blue: blue.map { $0 * gain })
    }
}

struct XDRModel: Equatable {
    static let nudge = 1.10
    static let minimumPotential = 1.05
    static let upStep = 0.03
    static let downShare = 0.25
    static let minimumDown = 0.01
    static let firstGeneration = XDRModel(reference: 3.2, bonus: 0.58)
    static let laterGenerations = XDRModel(reference: 2.66, bonus: 0.48)

    let reference: Double
    let bonus: Double

    func factor(level: Double, headroom: Double, potential: Double) -> Double {
        guard potential > Self.minimumPotential, level > 0 else { return 1 }
        guard headroom > 1 else { return Self.nudge }
        return min(1 + level * bonus * min(headroom / reference, 1), headroom)
    }

    static func smooth(current: Double, target: Double) -> Double {
        if target > current { return min(current + upStep, target) }
        return max(current - max((current - target) * downShare, minimumDown), target)
    }
}

struct MediaKey: Equatable {
    static let brightnessUp = 2
    static let brightnessDown = 3
    static let pressed = 0x0A
    static let released = 0x0B
    static let subtype: Int16 = 8

    let code: Int
    let isDown: Bool
    let isRepeat: Bool

    init(code: Int, isDown: Bool, isRepeat: Bool) {
        self.code = code
        self.isDown = isDown
        self.isRepeat = isRepeat
    }

    init?(data1: Int) {
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        guard state == Self.pressed || state == Self.released else { return nil }
        self.init(code: (data1 & 0xFFFF_0000) >> 16, isDown: state == Self.pressed, isRepeat: flags & 1 == 1)
    }
}

enum DDCProbe: Equatable {
    case live(DDCReading)
    case writeOnly
    case none
}

enum BrightnessRoute: String, Codable, Equatable {
    case system, ddc, picture

    static func choose(systemLevel: Double?, probe: DDCProbe, forcesPicture: Bool) -> BrightnessRoute {
        if systemLevel != nil { return .system }
        if forcesPicture { return .picture }
        switch probe {
        case .live, .writeOnly: return .ddc
        case .none: return .picture
        }
    }

    var title: String {
        switch self {
        case .system: "Built-in control"
        case .ddc: "Monitor control"
        case .picture: "Picture dimming"
        }
    }
}

enum BrightnessKeys {
    static let f14Key: UInt16 = 107
    static let f15Key: UInt16 = 113

    static func functionKeyDirection(keyCode: UInt16) -> Bool? {
        switch keyCode {
        case f14Key: false
        case f15Key: true
        default: nil
        }
    }

    static func handles(route: BrightnessRoute, isBuiltIn: Bool) -> Bool {
        !(route == .system && isBuiltIn)
    }

    static func step(for flags: CGEventFlags, default step: LevelStep) -> LevelStep? {
        guard flags.intersection([.maskCommand, .maskControl]).isEmpty else { return nil }
        let hasOption = flags.contains(.maskAlternate)
        if hasOption && flags.contains(.maskShift) { return .quarter }
        return hasOption ? nil : step
    }
}

struct MonitorIdentity: Equatable {
    static let locationWeight = 10
    static let unknownCode = 0xFFFF

    var vendor: Int
    var product: Int
    var serial: Int
    var name: String
    var location: String

    var isIdentified: Bool {
        vendor != 0 && product != 0 && vendor != Self.unknownCode && product != Self.unknownCode
    }

    var key: String {
        isIdentified ? String(format: "%x:%x:%d", vendor, product, serial) : "\(name)@\(location)"
    }

    func score(against other: MonitorIdentity) -> Int {
        var score = 0
        if vendor != 0 && vendor == other.vendor { score += 1 }
        if product != 0 && product == other.product { score += 1 }
        if serial != 0 && serial == other.serial { score += 1 }
        if !name.isEmpty && name == other.name { score += 1 }
        if !location.isEmpty && location == other.location { score += Self.locationWeight }
        return score
    }
}

enum MonitorMatcher {
    static func pair(_ monitors: [MonitorIdentity], with services: [MonitorIdentity]) -> [Int: Int] {
        if monitors.count == 1 && services.count == 1 { return [0: 0] }
        var candidates: [(monitor: Int, service: Int, score: Int)] = []
        for (monitorIndex, monitor) in monitors.enumerated() {
            for (serviceIndex, service) in services.enumerated() {
                let score = monitor.score(against: service)
                if score > 0 { candidates.append((monitorIndex, serviceIndex, score)) }
            }
        }
        var pairs: [Int: Int] = [:]
        var taken: Set<Int> = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) where pairs[candidate.monitor] == nil && !taken.contains(candidate.service) {
            pairs[candidate.monitor] = candidate.service
            taken.insert(candidate.service)
        }
        return pairs
    }
}
