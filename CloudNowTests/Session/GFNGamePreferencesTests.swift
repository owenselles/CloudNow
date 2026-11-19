@testable import CloudNow
import Foundation
import Testing

@Suite("Per-game launch presentation and mixed input")
struct GFNGamePreferencesTests {
    @Test("A title can use a desktop launcher without changing another title or stream quality")
    func independentOverrides() {
        var settings = StreamSettings()
        settings.fps = 30
        settings.chromaFormat = .yuv444
        settings.setGamePreferences(.init(launchMode: .default, remoteMode: .gamepadMouse), for: "anno")
        settings.setGamePreferences(.init(launchMode: .bigPicture, remoteMode: .dualsense), for: "other")

        let desktop = settings.applyingGamePreferences(for: "anno")
        #expect(desktop.appLaunchMode.cloudMatchValue == 1)
        #expect(desktop.defaultRemoteInputMode == .gamepadMouse)
        #expect(desktop.fps == 30)
        #expect(desktop.chromaFormat == .yuv444)
        #expect(settings.appLaunchMode == .bigPicture)
        #expect(settings.defaultRemoteInputMode == .gamepad)
        #expect(settings.applyingGamePreferences(for: "other").appLaunchMode == .bigPicture)
        #expect(settings.applyingGamePreferences(for: "other").defaultRemoteInputMode == .dualsense)
        #expect(settings.applyingGamePreferences(for: "unknown") == settings)
    }

    @Test("An inherited field follows later app changes; clearing both removes the override")
    func inheritance() {
        var settings = StreamSettings()
        settings.setGamePreferences(.init(launchMode: .default), for: "anno")
        settings.defaultRemoteInputMode = .dualsense
        #expect(settings.applyingGamePreferences(for: "anno").defaultRemoteInputMode == .dualsense)
        settings.setGamePreferences(.init(), for: "anno")
        #expect(settings.gamePreferences.isEmpty)
        #expect(settings.applyingGamePreferences(for: "anno") == settings)
    }

    @Test("Legacy settings migrate without preferences and new overrides survive persistence")
    func migrationAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(StreamSettings.self, from: Data("{\"fps\":30,\"appLaunchMode\":\"bigPicture\"}".utf8))
        #expect(legacy.gamePreferences.isEmpty)
        #expect(legacy.fps == 30)
        var settings = legacy
        settings.setGamePreferences(.init(launchMode: .default, remoteMode: .gamepadMouse), for: "anno")
        let restored = try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
        #expect(restored.applyingGamePreferences(for: "anno").appLaunchMode == .default)
    }
}
