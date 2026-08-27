@testable import CloudNow
import Testing

@Suite("Cloud settings eligibility policies")
struct CloudNowSettingsEligibilityTests {
    @Suite("GeForce NOW frame rates")
    struct GFNFrameRates {
        @Test("Entitled frame rates within the display limit are available")
        func eligibleFrameRates() {
            let eligibility = GFNSettingsEligibilityPolicy.frameRates(
                entitledResolutions: [
                    entitlement(width: 1920, height: 1080, framesPerSecond: 30),
                    entitlement(width: 1920, height: 1080, framesPerSecond: 60),
                ],
                selectedResolution: "1920x1080",
                maximumFramesPerSecond: 60
            )

            #expect(eligibility == [
                GFNFrameRateEligibility(framesPerSecond: 30, restriction: nil),
                GFNFrameRateEligibility(framesPerSecond: 60, restriction: nil),
            ])
        }

        @Test("The display limit identifies otherwise-entitled frame rates")
        func displayRestriction() {
            let eligibility = GFNSettingsEligibilityPolicy.frameRates(
                entitledResolutions: [
                    entitlement(width: 1920, height: 1080, framesPerSecond: 30),
                    entitlement(width: 1920, height: 1080, framesPerSecond: 60),
                ],
                selectedResolution: "1920x1080",
                maximumFramesPerSecond: 30
            )

            #expect(eligibility == [
                GFNFrameRateEligibility(framesPerSecond: 30, restriction: nil),
                GFNFrameRateEligibility(
                    framesPerSecond: 60,
                    restriction: .display(maximumFramesPerSecond: 30)
                ),
            ])
        }

        @Test("The membership identifies frame rates missing at the selected resolution")
        func membershipRestriction() {
            let eligibility = GFNSettingsEligibilityPolicy.frameRates(
                entitledResolutions: [
                    entitlement(width: 1920, height: 1080, framesPerSecond: 30),
                ],
                selectedResolution: "1920x1080",
                maximumFramesPerSecond: 60
            )

            #expect(eligibility == [
                GFNFrameRateEligibility(framesPerSecond: 30, restriction: nil),
                GFNFrameRateEligibility(
                    framesPerSecond: 60,
                    restriction: .membership
                ),
            ])
        }

        @Test("Display and membership limits are reported together")
        func displayAndMembershipRestriction() {
            let eligibility = GFNSettingsEligibilityPolicy.frameRates(
                entitledResolutions: [
                    entitlement(width: 1920, height: 1080, framesPerSecond: 30),
                ],
                selectedResolution: "1920x1080",
                maximumFramesPerSecond: 30
            )

            #expect(eligibility == [
                GFNFrameRateEligibility(framesPerSecond: 30, restriction: nil),
                GFNFrameRateEligibility(
                    framesPerSecond: 60,
                    restriction: .displayAndMembership(maximumFramesPerSecond: 30)
                ),
            ])
        }

        @Test("An exact resolution does not borrow another resolution's frame rates")
        func exactResolutionEligibility() {
            let eligibility = GFNSettingsEligibilityPolicy.frameRates(
                entitledResolutions: [
                    entitlement(width: 1920, height: 1080, framesPerSecond: 60),
                    entitlement(width: 3840, height: 2160, framesPerSecond: 120),
                ],
                selectedResolution: "1920x1080",
                maximumFramesPerSecond: 120
            )

            #expect(eligibility == [
                GFNFrameRateEligibility(framesPerSecond: 30, restriction: .membership),
                GFNFrameRateEligibility(framesPerSecond: 60, restriction: nil),
                GFNFrameRateEligibility(framesPerSecond: 120, restriction: .membership),
            ])
        }

        @Test("A missing selected resolution falls back to all account entitlements")
        func missingResolutionFallback() {
            let eligibility = GFNSettingsEligibilityPolicy.frameRates(
                entitledResolutions: [
                    entitlement(width: 1920, height: 1080, framesPerSecond: 60),
                    entitlement(width: 3840, height: 2160, framesPerSecond: 120),
                ],
                selectedResolution: "2560x1440",
                maximumFramesPerSecond: 120
            )

            #expect(eligibility == [
                GFNFrameRateEligibility(framesPerSecond: 30, restriction: .membership),
                GFNFrameRateEligibility(framesPerSecond: 60, restriction: nil),
                GFNFrameRateEligibility(framesPerSecond: 120, restriction: nil),
            ])
        }

        private func entitlement(
            width: Int,
            height: Int,
            framesPerSecond: Int
        ) -> EntitledResolution {
            EntitledResolution(
                widthInPixels: width,
                heightInPixels: height,
                framesPerSecond: framesPerSecond
            )
        }
    }

    @Suite("Xbox resolutions")
    struct XboxResolutions {
        private let standardResolutions: Set<XboxCloudDisplayResolution> = [
            .automatic,
            .fullHD,
            .hd,
        ]

        @Test("Membership loading restricts only unavailable manual resolutions")
        func checkingMembership() {
            #expect(restriction(for: .automatic, context: .checking) == nil)
            #expect(restriction(for: .fullHD, context: .checking) == nil)
            #expect(
                restriction(for: .qhd, context: .checking)
                    == .checkingMembership
            )
        }

        @Test("A failed membership check explains why premium resolutions are unavailable")
        func membershipUnavailable() {
            #expect(
                restriction(for: .qhd, context: .unavailable)
                    == .membershipUnavailable
            )
        }

        @Test("A known non-Ultimate membership requires Ultimate")
        func nonUltimateMembership() {
            #expect(
                restriction(for: .qhd, context: .loaded(.premium))
                    == .requiresUltimate(currentMembership: .premium)
            )
        }

        @Test("An unknown membership requires confirmed Ultimate access")
        func unknownMembership() {
            #expect(
                restriction(for: .qhd, context: .loaded(nil))
                    == .requiresConfirmedUltimate
            )
        }

        @Test("Ultimate resolutions are available when included in account capabilities")
        func ultimateMembership() {
            let availableResolutions = standardResolutions.union([
                .qhd,
                .fullHDHighQuality,
                .hdHighQuality,
            ])

            #expect(
                XboxSettingsEligibilityPolicy.resolutionRestriction(
                    for: .qhd,
                    availableResolutions: availableResolutions,
                    context: .loaded(.ultimate)
                ) == nil
            )
        }

        private func restriction(
            for resolution: XboxCloudDisplayResolution,
            context: XboxResolutionEligibilityContext
        ) -> XboxResolutionRestriction? {
            XboxSettingsEligibilityPolicy.resolutionRestriction(
                for: resolution,
                availableResolutions: standardResolutions,
                context: context
            )
        }
    }

    @Suite("Microphone permission")
    struct MicrophonePermission {
        @Test("Turning the microphone off never requests permission")
        func turnOff() {
            #expect(
                CloudNowMicrophoneSettingsPolicy.action(
                    requestedValue: false,
                    permissionStatus: .undetermined
                ) == .setEnabled(false)
            )
        }

        @Test("Enabling an undetermined microphone requests permission")
        func undeterminedPermission() {
            #expect(
                CloudNowMicrophoneSettingsPolicy.action(
                    requestedValue: true,
                    permissionStatus: .undetermined
                ) == .requestPermission
            )
        }

        @Test("Enabling a denied microphone remains blocked")
        func deniedPermission() {
            #expect(
                CloudNowMicrophoneSettingsPolicy.action(
                    requestedValue: true,
                    permissionStatus: .denied
                ) == .blocked
            )
        }

        @Test("Enabling a permitted microphone updates the preference")
        func grantedPermission() {
            #expect(
                CloudNowMicrophoneSettingsPolicy.action(
                    requestedValue: true,
                    permissionStatus: .granted
                ) == .setEnabled(true)
            )
        }
    }
}
