import Charts
import SwiftUI

struct HomeHealth: Equatable {
    let title: String
    let detail: String
    let icon: String
    let isWarning: Bool

    static let diskWarnPercent = 90.0
    static let memoryWarnPercent = 85.0
    static let cpuWarnPercent = 80.0

    static func summarize(cpu: Double, memory: Double, disk: Double, freeText: String) -> HomeHealth {
        if disk >= diskWarnPercent {
            return HomeHealth(title: "Your disk is almost full", detail: "Only \(freeText) left — a cleanup will help.",
                              icon: "exclamationmark.triangle.fill", isWarning: true)
        }
        if memory >= memoryWarnPercent {
            return HomeHealth(title: "Memory is under pressure", detail: "Quit a few heavy apps to free up RAM.",
                              icon: "memorychip.fill", isWarning: true)
        }
        if cpu >= cpuWarnPercent {
            return HomeHealth(title: "Your Mac is working hard", detail: "CPU is busy right now.",
                              icon: "flame.fill", isWarning: true)
        }
        return HomeHealth(title: "Everything looks great", detail: "\(freeText) free and running smoothly.",
                          icon: "checkmark.seal.fill", isWarning: false)
    }
}

struct AuroraBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            AuroraLayers()
        }
        .ignoresSafeArea()
    }
}

struct AuroraLayers: NSViewRepresentable {
    func makeNSView(context: Context) -> AuroraView { AuroraView() }
    func updateNSView(_ view: AuroraView, context: Context) {}

    final class AuroraView: NSView {
        private static let blobs: [(NSColor, CGFloat, CGFloat, Double)] = [
            (NSColor(red: 0.42, green: 0.36, blue: 0.95, alpha: 1), 0.15, 0.05, 0),
            (NSColor(red: 0.95, green: 0.42, blue: 0.68, alpha: 1), 0.85, 0.15, 2.1),
            (NSColor(red: 0.25, green: 0.78, blue: 0.80, alpha: 1), 0.70, 0.95, 4.2),
        ]
        private static let period: CFTimeInterval = 2 * .pi * 9
        private static let opacity: CGFloat = 0.22

        private var glows: [CAGradientLayer] = []
        private var laidOutSize: CGSize = .zero

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            glows = Self.blobs.map { blob in
                let glow = CAGradientLayer()
                glow.type = .radial
                glow.colors = [blob.0.withAlphaComponent(Self.opacity).cgColor, blob.0.withAlphaComponent(0).cgColor]
                glow.startPoint = CGPoint(x: 0.5, y: 0.5)
                glow.endPoint = CGPoint(x: 1, y: 1)
                layer?.addSublayer(glow)
                return glow
            }
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            guard bounds.size != laidOutSize, bounds.width > 0 else { return }
            laidOutSize = bounds.size
            let side = bounds.width * 0.9
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (glow, blob) in zip(glows, Self.blobs) {
                let center = CGPoint(x: bounds.width * blob.1, y: bounds.height * blob.2)
                glow.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                glow.position = center
                glow.add(drift(around: center, phase: blob.3), forKey: "drift")
            }
            CATransaction.commit()
        }

        private func drift(around center: CGPoint, phase: Double) -> CAAnimation {
            let rect = CGRect(x: center.x - bounds.width * 0.06, y: center.y - bounds.height * 0.05,
                              width: bounds.width * 0.12, height: bounds.height * 0.10)
            let animation = CAKeyframeAnimation(keyPath: "position")
            animation.path = CGPath(ellipseIn: rect, transform: nil)
            animation.duration = Self.period
            animation.timeOffset = phase / (2 * .pi) * Self.period
            animation.repeatCount = .infinity
            animation.calculationMode = .paced
            return animation
        }
    }
}

struct SoftGlow: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            RadialGradient(colors: [color, color.opacity(0)], center: .center,
                           startRadius: 0, endRadius: min(geo.size.width, geo.size.height) / 2)
        }
    }
}

struct DiskGauge: View {
    let usedPercent: Double
    let freeText: String
    @State private var progress: CGFloat = 0

    private static let arc = AngularGradient(
        colors: [.white, Color(red: 1, green: 0.85, blue: 0.95), Color(red: 0.75, green: 0.95, blue: 1), .white],
        center: .center, startAngle: .degrees(0), endAngle: .degrees(360))

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 14)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Self.arc, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: .white.opacity(0.5), radius: 8)
            VStack(spacing: 0) {
                Text("\(Int(usedPercent.rounded()))%")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("DISK USED")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.6)
                    .opacity(0.7)
                Text(freeText)
                    .font(.caption.weight(.medium))
                    .opacity(0.85)
                    .padding(.top, 4)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 168, height: 168)
        .onAppear { animate() }
        .onChange(of: usedPercent) { _, _ in animate() }
    }

    private func animate() {
        withAnimation(.spring(duration: 1.2, bounce: 0.15)) {
            progress = CGFloat(min(max(usedPercent / 100, 0), 1))
        }
    }
}

struct VitalTile: View {
    let title: String
    let icon: String
    let value: String
    let caption: String
    var history: [Double] = []
    var fraction: Double?
    let colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 8))
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let fraction {
                UsageBar(fraction: fraction, colors: colors)
                    .frame(height: 38, alignment: .bottom)
            } else {
                Sparkline(values: history, colors: colors)
                    .frame(height: 38)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .homeCard()
    }
}

struct Sparkline: View {
    let values: [Double]
    let colors: [Color]

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { point in
            AreaMark(x: .value("t", point.offset), y: .value("v", point.element))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [colors[0].opacity(0.35), colors[0].opacity(0)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("t", point.offset), y: .value("v", point.element))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .foregroundStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...100)
        .chartXScale(domain: 0...max(values.count - 1, 1))
        .animation(.easeInOut(duration: 0.6), value: values)
    }
}

struct UsageBar: View {
    let fraction: Double
    let colors: [Color]
    @State private var shown: Double = 0

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * min(max(shown, 0), 1))
                        .shadow(color: colors[0].opacity(0.4), radius: 6)
                }
            }
            .frame(height: 10)
        }
        .onAppear { withAnimation(.spring(duration: 1.1, bounce: 0.15)) { shown = fraction } }
        .onChange(of: fraction) { _, new in withAnimation(.snappy) { shown = new } }
    }
}

struct ToolTile: View {
    let icon: String
    let title: String
    let stat: String
    let colors: [Color]
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: colors[0].opacity(isHovered ? 0.5 : 0.25), radius: isHovered ? 10 : 5, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(stat).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(12)
            .homeCard(cornerRadius: 16)
            .scaleEffect(isHovered ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in withAnimation(.spring(duration: 0.3)) { isHovered = hovering } }
    }
}

struct CleanableBar: View {
    let segments: [(ArtifactCategory, Int, Int64)]
    @State private var revealed = false

    var body: some View {
        let total = max(segments.reduce(0) { $0 + $1.2 }, 1)
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(segments, id: \.0) { category, _, size in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(category.color.gradient)
                        .frame(width: max(6, (geo.size.width - CGFloat(segments.count) * 3) * CGFloat(size) / CGFloat(total)))
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .mask(alignment: .leading) {
                Rectangle().frame(width: revealed ? geo.size.width : 0)
            }
        }
        .frame(height: 14)
        .onAppear { withAnimation(.easeOut(duration: 0.9).delay(0.2)) { revealed = true } }
    }
}

struct HomeAppear: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(.spring(duration: 0.55, bounce: 0.2).delay(0.06 * Double(index))) { shown = true }
            }
    }
}

extension View {
    func homeCard(cornerRadius: CGFloat = 20) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    func homeAppear(_ index: Int) -> some View {
        modifier(HomeAppear(index: index))
    }
}
