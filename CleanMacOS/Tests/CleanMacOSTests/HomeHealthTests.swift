import SwiftUI
import Testing
@testable import CleanMacOS

struct HomeHealthTests {
    @Test func picksTheMostUrgentWarningFirst() {
        #expect(HomeHealth.summarize(cpu: 95, memory: 95, disk: 92, freeText: "10 GB").title == "Your disk is almost full")
        #expect(HomeHealth.summarize(cpu: 95, memory: 90, disk: 50, freeText: "10 GB").title == "Memory is under pressure")
        #expect(HomeHealth.summarize(cpu: 85, memory: 40, disk: 50, freeText: "10 GB").title == "Your Mac is working hard")
        let calm = HomeHealth.summarize(cpu: 20, memory: 40, disk: 50, freeText: "120 GB")
        #expect(!calm.isWarning)
        #expect(calm.detail.hasPrefix("120 GB free"))
    }
}

struct SparklineShapeTests {
    @Test func drawsAcrossTheWholeRectAndClosesTheArea() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
        #expect(SparklineShape(values: [50], isClosed: false).path(in: rect).isEmpty)
        let line = SparklineShape(values: [0, 100, 50], isClosed: false).path(in: rect).boundingRect
        #expect(line.minX == 0 && line.maxX == 100)
        #expect(abs(line.minY) < 0.5 && abs(line.maxY - 40) < 0.5)
        let area = SparklineShape(values: [80, 80], isClosed: true).path(in: rect).boundingRect
        #expect(area.maxY == 40 && abs(area.minY - 8) < 0.5)
        #expect(SparklineShape(values: [150, -20], isClosed: false).path(in: rect).boundingRect.height <= 40)
    }
}
