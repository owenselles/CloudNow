import Foundation

nonisolated struct GFNFrameRateEligibility: Equatable, Sendable {
    nonisolated enum Restriction: Equatable, Sendable {
        case display(maximumFramesPerSecond: Int)
        case membership
        case displayAndMembership(maximumFramesPerSecond: Int)
    }

    let framesPerSecond: Int
    let restriction: Restriction?

    var isAvailable: Bool {
        restriction == nil
    }
}

nonisolated enum GFNSettingsEligibilityPolicy {
    private static let fallbackFrameRates = [30, 60]

    static func frameRates(
        entitledResolutions: [EntitledResolution]?,
        selectedResolution: String,
        maximumFramesPerSecond: Int
    ) -> [GFNFrameRateEligibility] {
        let displayMaximum = max(1, maximumFramesPerSecond)
        guard let entitledResolutions, !entitledResolutions.isEmpty else {
            return fallbackFrameRates.map {
                GFNFrameRateEligibility(
                    framesPerSecond: $0,
                    restriction: $0 <= displayMaximum
                        ? nil
                        : .display(maximumFramesPerSecond: displayMaximum)
                )
            }
        }

        let selectedDimensions = selectedResolution
            .split(separator: "x")
            .compactMap { Int($0) }
        let selectedWidth = selectedDimensions.first ?? 1920
        let selectedHeight = selectedDimensions.last ?? 1080
        let matchingEntitlements = entitledResolutions.filter {
            $0.widthInPixels == selectedWidth
                && $0.heightInPixels == selectedHeight
        }
        let applicableEntitlements = matchingEntitlements.isEmpty
            ? entitledResolutions
            : matchingEntitlements
        let membershipFrameRates = Set(
            applicableEntitlements.map(\.framesPerSecond)
        )
        let candidateFrameRates = Set(
            fallbackFrameRates + entitledResolutions.map(\.framesPerSecond)
        )

        return candidateFrameRates.sorted().map { framesPerSecond in
            let membershipAllows = membershipFrameRates.contains(framesPerSecond)
            let displayAllows = framesPerSecond <= displayMaximum
            let restriction: GFNFrameRateEligibility.Restriction? = switch (
                membershipAllows,
                displayAllows
            ) {
            case (true, true):
                nil
            case (true, false):
                .display(maximumFramesPerSecond: displayMaximum)
            case (false, true):
                .membership
            case (false, false):
                .displayAndMembership(maximumFramesPerSecond: displayMaximum)
            }
            return GFNFrameRateEligibility(
                framesPerSecond: framesPerSecond,
                restriction: restriction
            )
        }
    }
}

nonisolated enum XboxResolutionEligibilityContext: Equatable, Sendable {
    case checking
    case unavailable
    case loaded(XboxMembershipTier?)
}

nonisolated enum XboxResolutionRestriction: Equatable, Sendable {
    case checkingMembership
    case membershipUnavailable
    case requiresUltimate(currentMembership: XboxMembershipTier)
    case requiresConfirmedUltimate
}

nonisolated enum XboxSettingsEligibilityPolicy {
    static func resolutionRestriction(
        for resolution: XboxCloudDisplayResolution,
        availableResolutions: Set<XboxCloudDisplayResolution>,
        context: XboxResolutionEligibilityContext
    ) -> XboxResolutionRestriction? {
        guard resolution != .automatic,
              !availableResolutions.contains(resolution)
        else {
            return nil
        }

        return switch context {
        case .checking:
            .checkingMembership
        case .unavailable:
            .membershipUnavailable
        case let .loaded(membershipTier):
            if let membershipTier {
                .requiresUltimate(currentMembership: membershipTier)
            } else {
                .requiresConfirmedUltimate
            }
        }
    }
}

nonisolated enum CloudNowMicrophonePermissionStatus: Equatable, Sendable {
    case undetermined
    case denied
    case granted
}

nonisolated enum CloudNowMicrophoneSettingsAction: Equatable, Sendable {
    case setEnabled(Bool)
    case requestPermission
    case blocked
}

nonisolated enum CloudNowMicrophoneSettingsPolicy {
    static func action(
        requestedValue: Bool,
        permissionStatus: CloudNowMicrophonePermissionStatus
    ) -> CloudNowMicrophoneSettingsAction {
        guard requestedValue else { return .setEnabled(false) }
        return switch permissionStatus {
        case .undetermined:
            .requestPermission
        case .denied:
            .blocked
        case .granted:
            .setEnabled(true)
        }
    }
}
