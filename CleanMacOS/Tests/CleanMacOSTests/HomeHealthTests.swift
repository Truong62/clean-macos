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
