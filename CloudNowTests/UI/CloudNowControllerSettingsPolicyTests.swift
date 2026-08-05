@testable import CloudNow
import Testing

@Suite("Shared controller settings policies")
struct CloudNowControllerSettingsPolicyTests {
    @Test("GFN preserves its multiplier and controller bounds")
    func geForceNowPolicy() {
        let policy = CloudNowControllerSettingsPolicy.geForceNow

        #expect(policy.rumbleLabel(for: 1) == "1.00×")
        #expect(policy.deadzoneLabel(for: 0.15) == "15%")
        #expect(policy.adjustedRumbleValue(2, direction: 1) == 2)
        #expect(policy.adjustedDeadzoneValue(0, direction: -1) == 0)
        #expect(abs(policy.adjustedRumbleValue(1, direction: -1) - 0.95) < 0.000_001)
        #expect(abs(policy.adjustedDeadzoneValue(0.15, direction: 1) - 0.16) < 0.000_001)
    }

    @Test("Xbox preserves percentage values while sharing row behavior")
    func xboxPolicy() {
        let policy = CloudNowControllerSettingsPolicy.xboxCloudGaming

        #expect(policy.rumbleLabel(for: 1) == "100%")
        #expect(policy.deadzoneLabel(for: 0.15) == "15%")
        #expect(policy.adjustedRumbleValue(1, direction: 1) == 1)
        #expect(policy.adjustedDeadzoneValue(0.30, direction: 1) == 0.30)
        #expect(abs(policy.adjustedRumbleValue(0.50, direction: -1) - 0.45) < 0.000_001)
        #expect(abs(policy.adjustedDeadzoneValue(0.15, direction: -1) - 0.14) < 0.000_001)
    }
}
