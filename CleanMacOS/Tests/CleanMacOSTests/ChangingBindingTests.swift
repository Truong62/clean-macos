import SwiftUI
import Testing
@testable import CleanMacOS

struct ChangingBindingTests {
    @Test func writesOnlyWhenTheValueChanges() {
        var stored = false
        var writes = 0
        let binding = Binding<Bool>.changing(get: { stored }, set: { stored = $0; writes += 1 })
        binding.wrappedValue = false
        binding.wrappedValue = false
        #expect(writes == 0)
        binding.wrappedValue = true
        binding.wrappedValue = true
        #expect(writes == 1 && stored)
    }
}
