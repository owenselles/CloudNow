@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox Cloud quality beta policy")
struct XboxCloudQualityBetaPolicyTests {
    @Test("Only a Beta build can resolve the Microsoft web profile")
    func profileGate() {
        #expect(
            XboxCloudQualityBetaPolicy.compatibilityProfile(
                for: .microsoftWeb,
                betaEnabled: true
            ).identifier == XboxCloudQualityProfilePreference.microsoftWeb.rawValue
        )
        #expect(
            XboxCloudQualityBetaPolicy.compatibilityProfile(
                for: .microsoftWeb,
                betaEnabled: false
            ).identifier == XboxCloudQualityProfilePreference.nativeTVControl.rawValue
        )
    }

    @Test("Only a Beta build can activate a manual bandwidth preference")
    func bandwidthGate() {
        let manual = XboxCloudBandwidthPreference.manual(
            maximumBitrateKbps: 100_000
        )
        #expect(
            XboxCloudQualityBetaPolicy.normalizedBandwidthPreference(
                manual,
                betaEnabled: true
            ) == manual
        )
        #expect(
            XboxCloudQualityBetaPolicy.normalizedBandwidthPreference(
                manual,
                betaEnabled: false
            ) == .automatic
        )
    }

    @Test("Profile preference persists and malformed values fail to control")
    func resilientPersistence() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let settings = XboxCloudStreamSettings(
            qualityProfile: .microsoftWeb
        )
        let restored = try decoder.decode(
            XboxCloudStreamSettings.self,
            from: encoder.encode(settings)
        )
        #expect(restored.qualityProfile == .microsoftWeb)

        let malformed = Data(#"{"qualityProfile":"private-session-value"}"#.utf8)
        let recovered = try decoder.decode(
            XboxCloudStreamSettings.self,
            from: malformed
        )
        #expect(recovered.qualityProfile == .nativeTVControl)
    }

    @Test("Current build normalization matches its compilation gate")
    func currentBuildGate() {
        let manualBandwidth = XboxCloudBandwidthPreference.manual(
            maximumBitrateKbps: 100_000
        )
        let normalized = XboxCloudStreamSettings(
            bandwidthPreference: manualBandwidth,
            qualityProfile: .microsoftWeb
        ).normalizedForClient
        #if XBOX_QUALITY_BETA
            #expect(XboxQualityBetaBuild.isEnabled)
            #expect(normalized.qualityProfile == .microsoftWeb)
            #expect(normalized.bandwidthPreference == manualBandwidth)
        #else
            #expect(!XboxQualityBetaBuild.isEnabled)
            #expect(normalized.qualityProfile == .nativeTVControl)
            #expect(normalized.bandwidthPreference == .automatic)
        #endif
    }
}
