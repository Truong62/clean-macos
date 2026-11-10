import Foundation
import Testing
@testable import CleanMacOS

struct CommandMathTests {
    private let english = Locale(identifier: "en_US")

    @Test func calculatesThroughRust() {
        #expect(RustCore.calculate("2+2*3")?.value == 8)
        #expect(RustCore.calculate("(1+2")?.closed == 1)
        #expect(RustCore.calculate("5") == nil)
        #expect(RustCore.calculate("2026-07-27") == nil)
    }

    @Test func formatsResultsReadably() {
        #expect(CalculatorFormat.text(0.1 + 0.2, locale: english) == "0.3")
        #expect(CalculatorFormat.text(1_234_567.891, locale: english) == "1,234,567.891")
        #expect(CalculatorFormat.text(2.0 / 3, locale: english) == "0.66666667")
        #expect(CalculatorFormat.text(-42, locale: english) == "-42")
        #expect(CalculatorFormat.text(1e13, locale: english) == "1e13")
        #expect(CalculatorFormat.text(1.234e-7, locale: english) == "1.234e-7")
        #expect(CalculatorFormat.text(1_234.5, locale: Locale(identifier: "vi_VN")) == "1.234,5")
    }

    @Test func convertsUnitsThroughRust() throws {
        let miles = try #require(RustCore.convert("100 km to mi"))
        #expect(miles.to == "mi")
        #expect(UnitFormat.text(miles, locale: english) == "62.14 mi")
        #expect(UnitFormat.text(try #require(RustCore.convert("180 cm to ft")), locale: english) == "5 ft 10.9 in")
        #expect(UnitFormat.text(try #require(RustCore.convert("500 g to kg")), locale: english) == "0.5 kg")
        #expect(UnitFormat.text(try #require(RustCore.convert("20c to f")), locale: english) == "68 °F")
        #expect(RustCore.convert("5 km to kg") == nil)
    }

    @Test func ranksThroughRust() {
        let rows = [RankRow(title: "Google Chrome", keywords: "browser"), RankRow(title: "Chrome"), RankRow(title: "Safari", keywords: "web\tbrowser")]
        #expect(RustCore.rank("chrome", rows).map(\.index) == [1, 0])
        #expect(RustCore.rank("BROWSER", rows).map(\.index) == [0, 2])
        #expect(RustCore.rank("café", [RankRow(title: "Cafe Menu")]).map(\.index) == [0])
        #expect(RustCore.rank("", rows).isEmpty)
    }
}
