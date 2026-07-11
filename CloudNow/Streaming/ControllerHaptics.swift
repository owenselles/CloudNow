import CoreHaptics
import Foundation
import GameController
import os.log

private let hapticsLog = Logger(subsystem: "com.owenselles.CloudNow2", category: "Haptics")

final nonisolated class ControllerHaptics {
    private final class Motor: @unchecked Sendable {
        let locality: GCHapticsLocality
        var engine: CHHapticEngine?
        var player: CHHapticPatternPlayer?
        var playing = false
        var loggedError = false
        var lastMagnitude: UInt16 = 0

        init(locality: GCHapticsLocality, engine: CHHapticEngine) {
            self.locality = locality
            self.engine = engine
        }

        func log(_ error: Error) {
            guard !loggedError else { return }

            let localityName = locality.rawValue
            hapticsLog.warning("[ControllerHaptics] \(localityName, privacy: .public) error: \(error, privacy: .private)")
            loggedError = true
        }
    }

    private let queue: DispatchQueue
    private let strongMotor: Motor?
    private let weakMotor: Motor?

    /// User-controlled rumble power (mirrors StreamSettings.rumbleIntensity). Mutate on `queue`.
    var intensityScale: Float = 1.0

    /// Perceptual gamma applied to raw magnitudes; <1 boosts subtle low-end rumble.
    private static let intensityCurveExponent: Float = 0.5

    init?(controller: GCController, queue: DispatchQueue) {
        guard let haptics = controller.haptics else {
            hapticsLog.warning("[Rumble] controller has NO haptics")
            return nil
        }
        hapticsLog.debug("[Rumble] haptics localities=\(String(describing: haptics.supportedLocalities.map(\.rawValue)), privacy: .public)")

        self.queue = queue
        strongMotor = Self.makeMotor(
            locality: GCHapticsLocality.leftHandle,
            haptics: haptics
        )
        weakMotor = Self.makeMotor(
            locality: GCHapticsLocality.rightHandle,
            haptics: haptics
        )

        if strongMotor == nil, weakMotor == nil {
            return nil
        }

        if let strongMotor {
            setHandlers(for: strongMotor)
        }
        if let weakMotor {
            setHandlers(for: weakMotor)
        }
    }

    /// Must be called on `queue`.
    func setMotors(strong: UInt16, weak: UInt16) {
        if let strongMotor {
            apply(strong, to: strongMotor)
        }
        if let weakMotor {
            apply(weak, to: weakMotor)
        }
    }

    /// On `queue`.
    func stop() {
        stop(strongMotor)
        stop(weakMotor)
    }

    /// On `queue`.
    func cleanup() {
        cleanup(strongMotor)
        cleanup(weakMotor)
    }

    private static func makeMotor(
        locality: GCHapticsLocality,
        haptics: GCDeviceHaptics
    ) -> Motor? {
        guard haptics.supportedLocalities.contains(locality),
              let engine = haptics.createEngine(withLocality: locality)
        else {
            return nil
        }

        do {
            try engine.start()
            hapticsLog.info("[Rumble] engine \(locality.rawValue, privacy: .public) started")
        } catch {
            hapticsLog.warning("[ControllerHaptics] \(locality.rawValue, privacy: .public) error: \(error, privacy: .private)")
            return nil
        }

        return Motor(locality: locality, engine: engine)
    }

    private func setHandlers(for motor: Motor) {
        motor.engine?.stoppedHandler = { [weak self, weak motor] _ in
            self?.queue.async {
                motor?.player = nil
                motor?.playing = false
            }
        }
        motor.engine?.resetHandler = { [weak self, weak motor] in
            self?.queue.async {
                motor?.player = nil
                motor?.playing = false
                do {
                    try motor?.engine?.start()
                } catch {
                    motor?.log(error)
                }
            }
        }
    }

    private func apply(_ magnitude: UInt16, to motor: Motor) {
        guard magnitude != motor.lastMagnitude else { return }
        motor.lastMagnitude = magnitude

        // Keep ONE continuous player running and modulate its intensity live, including
        // down to zero. GFN streams rumble at frame-rate and oscillates through 0 many
        // times per second; stopping/restarting the player on every zero produced a
        // choppy "brrr-brrr" texture. Create the player lazily on the first non-zero
        // magnitude, then never stop it until pause/detach.
        if motor.player == nil {
            guard magnitude > 0, let player = makePlayer(for: motor) else { return }
            motor.player = player
        }

        let parameter = CHHapticDynamicParameter(
            parameterID: .hapticIntensityControl,
            value: Self.curvedIntensity(magnitude, scale: intensityScale),
            relativeTime: 0
        )
        do {
            try motor.player?.sendParameters([parameter], atTime: CHHapticTimeImmediate)
        } catch {
            motor.log(error)
        }

        guard !motor.playing else { return }
        do {
            try motor.player?.start(atTime: 0)
            motor.playing = true
        } catch {
            motor.log(error)
        }
    }

    /// Maps a 0–65535 XInput magnitude to a Core Haptics intensity in 0…1.
    /// A gamma curve (<1 exponent) lifts the low end so subtle in-game rumble is
    /// actually felt, and `scale` (the user's Rumble Power) multiplies before clamping.
    private static func curvedIntensity(_ magnitude: UInt16, scale: Float) -> Float {
        guard magnitude > 0 else { return 0 }
        let normalized = Float(magnitude) / 65535.0
        let curved = powf(normalized, intensityCurveExponent)
        return min(curved * scale, 1.0)
    }

    private func makePlayer(for motor: Motor) -> CHHapticPatternPlayer? {
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
            ],
            relativeTime: 0,
            duration: TimeInterval(Double(GCHapticDurationInfinite))
        )

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            return try motor.engine?.makePlayer(with: pattern)
        } catch {
            motor.log(error)
            return nil
        }
    }

    private func stop(_ motor: Motor?) {
        guard let motor else { return }

        do {
            try motor.player?.stop(atTime: 0)
        } catch {
            motor.log(error)
        }
        motor.playing = false
        motor.lastMagnitude = 0
    }

    private func cleanup(_ motor: Motor?) {
        guard let motor else { return }

        do {
            try motor.player?.cancel()
        } catch {
            motor.log(error)
        }
        motor.engine?.stop(completionHandler: nil)
        motor.player = nil
        motor.engine = nil
        motor.playing = false
        motor.lastMagnitude = 0
    }
}
