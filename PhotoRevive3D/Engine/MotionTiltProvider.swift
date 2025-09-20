//  MotionTiltProvider.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import Foundation
@preconcurrency import CoreMotion
import Combine
import UIKit

// MARK: - Core helpers

@inline(__always) private func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double {
    return min(max(x, a), b)
}

@inline(__always) private func applyDeadzone(_ v: Double, dz: Double) -> Double {
    let a = abs(v)
    if a <= dz { return 0 }
    let sign = v >= 0 ? 1.0 : -1.0
    return sign * (a - dz) / (1 - dz)
}

// MARK: - Background service (no @MainActor)

/// CoreMotion service that delivers callbacks on the main thread.
/// High-quality path: screen-rate sampling (60–120 Hz), deadzone,
/// optional non-linear response, and time-constant smoothing.
final class MotionTiltService {

    struct Config {
        /// Target sampling rate in Hz.
        var hz: Double
        /// Degrees of physical tilt that map to ±1.0 in the normalised output.
        var sensitivityDegrees: Double
        /// Small deadzone to prevent jitter around zero (0…0.2 is typical).
        var deadzone: Double
        /// Apply a gentle non-linear curve (tanh) to soften the extremes.
        var nonlinearResponse: Bool
        /// Smoothing time-constant in seconds (0 disables smoothing).
        var smoothingTau: Double

        static func `default`(hz: Double) -> Config {
            let target = min(max(hz, 30), 120)
            return Config(
                hz: target,
                sensitivityDegrees: 30,   // ±30° → ±1.0
                deadzone: 0.02,           // 2% deadzone
                nonlinearResponse: true,  // tanh shaping
                smoothingTau: 0.08        // ~80 ms TC
            )
        }
    }

    static var isAvailable: Bool { CMMotionManager().isDeviceMotionAvailable }

    private let mgr = CMMotionManager()
    private(set) var active = false

    // Main-actor closures (we deliver on the main queue).
    private var sampleHandler: (@MainActor (Double, Double) -> Void)?
    private var errorHandler: (@MainActor (Error) -> Void)?

    // Config and smoothing state
    private var config: Config = .default(hz: 60)
    private var lastTimestamp: TimeInterval?
    private var smoothedYaw: Double?
    private var smoothedPitch: Double?

    deinit {
        mgr.stopDeviceMotionUpdates()
    }

    /// Starts device motion and delivers *main-thread* callbacks.
    func start(
        config: Config,
        onSample: @escaping @MainActor (Double, Double) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        guard !active, mgr.isDeviceMotionAvailable else { return }

        self.config = config
        active = true
        sampleHandler = onSample
        errorHandler = onError
        lastTimestamp = nil
        smoothedYaw = nil
        smoothedPitch = nil

        mgr.deviceMotionUpdateInterval = 1.0 / max(1.0, config.hz)

        // Run the handler on the MAIN operation queue to satisfy MainActor isolation.
        mgr.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] motion, error in
            #if DEBUG
            dispatchPrecondition(condition: .onQueue(.main))
            #endif
            guard let self, self.active else { return }

            if let error {
                self.errorHandler?(error)
                return
            }
            guard let m = motion else { return }

            // --- Normalise yaw/pitch by sensitivity (±degrees → ±1) ---
            let maxAngle = self.config.sensitivityDegrees * .pi / 180.0
            var yawNorm   = clamp(m.attitude.yaw   / maxAngle, -1, 1)
            var pitchNorm = clamp(m.attitude.pitch / maxAngle, -1, 1)

            // --- Deadzone (recenter small jitters to 0) ---
            if self.config.deadzone > 0 {
                yawNorm   = applyDeadzone(yawNorm,   dz: self.config.deadzone)
                pitchNorm = applyDeadzone(pitchNorm, dz: self.config.deadzone)
            }

            // --- Non-linear shaping near extremes (gentler feel) ---
            if self.config.nonlinearResponse {
                yawNorm   = tanh(yawNorm   * 1.5)
                pitchNorm = tanh(pitchNorm * 1.5)
            }

            // --- Exponential smoothing with time-constant (in seconds) ---
            if self.config.smoothingTau > 0 {
                let dt: TimeInterval
                if let last = self.lastTimestamp {
                    dt = max(0, m.timestamp - last)
                } else {
                    dt = 1.0 / max(1.0, self.config.hz)
                }
                self.lastTimestamp = m.timestamp

                // Convert tau→alpha per sample: alpha = 1 - e^( -dt / tau )
                let alpha = 1 - exp(-dt / self.config.smoothingTau)

                if let sY = self.smoothedYaw {
                    yawNorm = sY + alpha * (yawNorm - sY)
                }
                if let sP = self.smoothedPitch {
                    pitchNorm = sP + alpha * (pitchNorm - sP)
                }
                self.smoothedYaw = yawNorm
                self.smoothedPitch = pitchNorm
            }

            self.sampleHandler?(yawNorm, pitchNorm)
        }
    }

    func stop() {
        guard active else { return }
        active = false
        mgr.stopDeviceMotionUpdates()
        sampleHandler = nil
        errorHandler = nil
        lastTimestamp = nil
        smoothedYaw = nil
        smoothedPitch = nil
    }
}

// MARK: - UI-facing provider (MainActor)

/// SwiftUI-friendly wrapper that holds published tilt values.
/// All state updates and logging happen on the main actor.
@MainActor
final class MotionTiltProvider: ObservableObject {

    @Published var yaw: Double = 0
    @Published var pitch: Double = 0

    private let service = MotionTiltService()
    private var didLogFirstSample = false

    /// Current quality profile; initialised from the *current scene’s screen* (iOS 26-safe).
    var config: MotionTiltService.Config

    init() {
        let hz = MotionTiltProvider.currentScreenRefreshRate()
        self.config = .default(hz: hz)
    }

    /// Start (idempotent from UI).
    func start() {
        Diagnostics.log(.info, "Gyro start requested (available=\(MotionTiltService.isAvailable))", category: "gyro")

        guard MotionTiltService.isAvailable else {
            Diagnostics.log(.warn, "Device motion not available on this device/simulator", category: "gyro")
            return
        }

        didLogFirstSample = false
        Diagnostics.log(
            .info,
            "Device motion updates STARTED (mode=.xArbitraryCorrectedZVertical @ \(Int(config.hz))Hz, sens=\(Int(config.sensitivityDegrees))°)",
            category: "gyro"
        )

        service.start(config: config) { [weak self] yaw, pitch in
            guard let self else { return }
            self.yaw = yaw
            self.pitch = pitch

            if !self.didLogFirstSample {
                self.didLogFirstSample = true
                let f3: (Double) -> String = { String(format: "%.3f", $0) }
                Diagnostics.log(
                    .info,
                    "First sample: yaw=\(f3(yaw)) pitch=\(f3(pitch)) (Hz=\(Int(self.config.hz)))",
                    category: "gyro"
                )
            }
        } onError: { err in
            Diagnostics.log(.error, "DeviceMotion handler error: \(err)", category: "gyro")
        }
    }

    /// Stop (idempotent).
    func stop() {
        Diagnostics.log(.info, "Gyro STOP requested", category: "gyro")
        service.stop()
        Diagnostics.log(.info, "Device motion updates STOPPED", category: "gyro")
    }

    /// iOS 26-safe way to get refresh rate: use the foreground window scene’s screen.
    private static func currentScreenRefreshRate() -> Double {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }

        if let screen = scenes.first?.screen {
            let fps = screen.maximumFramesPerSecond
            return fps > 0 ? Double(fps) : 60
        }

        // Fallback: any scene’s screen, then 60 Hz.
        if let anyScreen = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.screen {
            let fps = anyScreen.maximumFramesPerSecond
            return fps > 0 ? Double(fps) : 60
        }

        return 60
    }
}
