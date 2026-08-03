@testable import CloudNow
import Foundation
import Testing

@Suite("Stream settings and migrations")
struct StreamSettingsTests {
    struct DoubleClampCase: Sendable {
        let input: Double
        let expected: Double
    }

    @Test("Defaults describe the conservative tvOS streaming profile")
    func defaults() {
        let settings = StreamSettings()

        #expect(settings.resolution == "1920x1080")
        #expect(settings.fps == 60)
        #expect(settings.maxBitrateKbps == 20000)
        #expect(settings.codec == .h264)
        #expect(settings.colorPreference == .automatic)
        #expect(settings.keyboardLayout == StreamSettings.defaultKeyboardLayout)
        #expect(settings.gameLanguage == StreamSettings.automaticGameLanguage)
        #expect(!settings.enableL4S)
        #expect(!settings.micEnabled)
        #expect(settings.rumbleEnabled)
        #expect(settings.rumbleIntensity == 1)
        #expect(settings.controllerDeadzone == 0.15)
        #expect(settings.overlayTriggerButton == .start)
        #expect(settings.defaultRemoteInputMode == .gamepad)
        #expect(settings.serverRoutingMode == .serverAuto)
        #expect(settings.preferredZoneUrl == nil)
        #expect(settings.statsMode == .off)
        #expect(!settings.diagnosticsEnabled)
        #expect(!settings.enableRtcEventLog)
        #expect(settings.appLaunchMode == .bigPicture)
        #expect(settings.persistInGameSettings)
        #expect(settings.audioFormat == .automatic)
    }

    @Test("Maximum bitrate is clamped to the selectable ceiling")
    func maximumBitrateClamping() {
        var settings = StreamSettings()

        settings.maxBitrateKbps = StreamSettings.maxSelectableBitrateKbps + 50000

        #expect(settings.maxBitrateKbps == StreamSettings.maxSelectableBitrateKbps)
    }

    @Test(
        "Controller deadzone clamps both bounds",
        arguments: [
            DoubleClampCase(input: -1, expected: 0),
            DoubleClampCase(input: 0.2, expected: 0.2),
            DoubleClampCase(input: 1, expected: 0.3),
        ]
    )
    func controllerDeadzoneClamping(testCase: DoubleClampCase) {
        var settings = StreamSettings()
        settings.controllerDeadzone = testCase.input

        #expect(settings.controllerDeadzone == testCase.expected)
    }

    @Test(
        "Rumble intensity clamps both bounds",
        arguments: [
            DoubleClampCase(input: -0.1, expected: 0),
            DoubleClampCase(input: 1.25, expected: 1.25),
            DoubleClampCase(input: 3, expected: 2),
        ]
    )
    func rumbleIntensityClamping(testCase: DoubleClampCase) {
        var settings = StreamSettings()
        settings.rumbleIntensity = testCase.input

        #expect(settings.rumbleIntensity == testCase.expected)
    }

    @Test("Current settings round-trip through Codable")
    func codableRoundTrip() throws {
        var expected = StreamSettings()
        expected.resolution = "2560x1440"
        expected.fps = 120
        expected.maxBitrateKbps = 75000
        expected.codec = .h265
        expected.colorPreference = .preferSDR10
        expected.keyboardLayout = "de-DE"
        expected.gameLanguage = "fr_FR"
        expected.enableL4S = true
        expected.micEnabled = true
        expected.rumbleEnabled = false
        expected.rumbleIntensity = 1.5
        expected.controllerDeadzone = 0.05
        expected.overlayTriggerButton = .options
        expected.defaultRemoteInputMode = .dualsense
        expected.serverRoutingMode = .region
        expected.preferredRegionName = "EU Central"
        expected.preferredRegionAddress = "https://eu.example.invalid/"
        expected.statsMode = .compact
        expected.diagnosticsEnabled = true
        expected.enableRtcEventLog = true
        expected.appLaunchMode = .default
        expected.persistInGameSettings = false
        expected.audioFormat = .surround51

        let encoded = try JSONEncoder().encode(expected)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: encoded)

        #expect(decoded == expected)
    }

    @Test("An older document with missing keys receives every current default")
    func missingKeysUseDefaults() throws {
        let decoded = try decodeFixture("minimal.json")

        #expect(decoded == StreamSettings())
    }

    @Test("Legacy color quality migrates and decoded values still clamp")
    func legacyColorQualityMigration() throws {
        let decoded = try decodeFixture("legacy-color.json")

        #expect(decoded.resolution == "3840x2160")
        #expect(decoded.fps == 120)
        #expect(decoded.maxBitrateKbps == 100_000)
        #expect(decoded.codec == .h265)
        #expect(decoded.colorPreference == .preferHDR)
        #expect(decoded.rumbleIntensity == 2)
        #expect(decoded.controllerDeadzone == 0)
    }

    @Test("Legacy diagnostic HUD preserves diagnostics and a visible standard HUD")
    func legacyDiagnosticMigration() throws {
        let decoded = try decodeFixture("legacy-diagnostic.json")

        #expect(decoded.statsMode == .standard)
        #expect(decoded.diagnosticsEnabled)
        #expect(decoded.enableRtcEventLog)
    }

    @Test("Legacy HUD value migrates to off and disables orphaned RTC logging")
    func legacyHUDMigration() throws {
        let decoded = try decodeFixture("legacy-hud.json")
        let normalized = decoded.normalizedForClient

        #expect(decoded.statsMode == .off)
        #expect(!decoded.diagnosticsEnabled)
        #expect(!normalized.enableRtcEventLog)
    }

    @Test("A legacy preferred zone selects client routing")
    func legacyPreferredZoneMigration() throws {
        let decoded = try decodeFixture("legacy-zone.json")

        #expect(decoded.serverRoutingMode == .client)
        #expect(decoded.preferredZoneUrl == "https://np-test.example.invalid/")
    }

    @Test("Unknown server routing falls back to server automatic")
    func unknownServerRoutingFallback() throws {
        let decoded = try decodeFixture("unknown-routing.json")

        #expect(decoded.serverRoutingMode == .serverAuto)
    }

    @Test("Invalid explicit routing selections normalize to automatic")
    func invalidRoutingNormalization() {
        var missingZone = StreamSettings()
        missingZone.serverRoutingMode = .client
        missingZone.preferredZoneUrl = nil

        var missingRegion = StreamSettings()
        missingRegion.serverRoutingMode = .region
        missingRegion.preferredRegionAddress = nil

        #expect(missingZone.normalizedForClient.serverRoutingMode == .serverAuto)
        #expect(missingRegion.normalizedForClient.serverRoutingMode == .serverAuto)
    }

    @Test("RTC event logging cannot remain enabled without diagnostics")
    func rtcLoggingRequiresDiagnostics() {
        var settings = StreamSettings()
        settings.diagnosticsEnabled = false
        settings.enableRtcEventLog = true

        #expect(!settings.normalizedForClient.enableRtcEventLog)
    }

    @Test(
        "Statistics HUD cycles through all user-visible levels",
        arguments: [
            (StreamStatsMode.off, StreamStatsMode.compact),
            (StreamStatsMode.compact, StreamStatsMode.standard),
            (StreamStatsMode.standard, StreamStatsMode.off),
        ]
    )
    func statsModeCycle(input: StreamStatsMode, expected: StreamStatsMode) {
        #expect(input.nextHUDLevel == expected)
    }

    @Test(
        "App launch modes map to CloudMatch wire values",
        arguments: [
            (AppLaunchMode.default, 1),
            (AppLaunchMode.bigPicture, 2),
        ]
    )
    func appLaunchWireValue(mode: AppLaunchMode, expected: Int) {
        #expect(mode.cloudMatchValue == expected)
    }

    @Test("Legacy mouse input mode migrates to simultaneous gamepad and mouse")
    func remoteInputLegacyMigration() throws {
        let decoded = try JSONDecoder().decode(RemoteInputMode.self, from: Data(#""mouse""#.utf8))

        #expect(decoded == .gamepadMouse)
        #expect(decoded.remoteActsAsMouse)
    }

    @Test("Unknown remote input mode fails decoding")
    func unknownRemoteInputFails() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RemoteInputMode.self, from: Data(#""telepathy""#.utf8))
        }
    }

    private func decodeFixture(_ name: String) throws -> StreamSettings {
        try JSONDecoder().decode(
            StreamSettings.self,
            from: TestFixture.data(name, subdirectory: "Settings")
        )
    }
}
