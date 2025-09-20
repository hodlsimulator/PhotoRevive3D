//  MotionTiltProvider.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//
//  iOS 26-ready (uses effectiveGeometry.interfaceOrientation)
//  Uses ROLL+PITCH mapped to screen axes (not yaw), with smoothing + baseline calibration.
//

import Foundation
@preconcurrency import CoreMotion
import Combine
import UIKit

// MARK: - Core helpers

@inline(__always)
private func clamp(_ x: Double, _ a: Double, _ b: Double) -> Double { min(max(x, a), b) }

@inline(__always)
private func applyDeadzone(_ v: Double, dz: Double) -> Double {
    let a = abs(v)
    if a <= dz { return 0 }
    let sign = v >= 0 ? 1.0 : -1.0
    return sign * (a - dz) / (1 - dz)
}

/// Current UI orientation from the foreground window scene (iOS 26).
@MainActor
private func currentInterfaceOrientation() -> UIInterfaceOrientation {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
        return active.effectiveGeometry.interfaceOrientation
    }
    return scenes.first?.effectiveGeometry.interfaceOrientation ?? .portrait
}

// MARK: - Background service (no @MainActor)

/// CoreMotion service that delivers callbacks on the main thread.
/// Screen-rate sampling (60–120 Hz), deadzone, optional non-linear response, and smoothing.
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

    // Main-actor closures (delivered on the main queue).
    private var sampleHandler: (@MainActor (Double, Double) -> Void)?
    private var errorHandler: (@MainActor (Error) -> Void)?

    // Config and state
    private var config: Config = .default(hz: 60)
    private var lastTimestamp: TimeInterval?
    private var smoothedX: Double?
    private var smoothedY: Double?

    // Baseline (centre) management
    private var baselineX: Double?
    private var baselineY: Double?
    private var baselineOnNextSample = false

    deinit { mgr.stopDeviceMotionUpdates() }

    /// Request that the next motion sample becomes the new baseline (centre).
    func requestBaselineReset() {
        baselineOnNextSample = true
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
        smoothedX = nil
        smoothedY = nil
        baselineX = nil
        baselineY = nil
        baselineOnNextSample = true  // auto-centre at start

        mgr.deviceMotionUpdateInterval = 1.0 / max(1.0, config.hz)

        // Deliver on MAIN to safely read UI orientation and satisfy MainActor isolation.
        mgr.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] motion, error in
            #if DEBUG
            dispatchPrecondition(condition: .onQueue(.main))
            #endif
            guard let self, self.active else { return }
            if let error { self.errorHandler?(error); return }
            guard let m = motion else { return }

            // --- Use ROLL (left–right tilt) + PITCH (forward–back tilt) in radians ---
            let roll  = m.attitude.roll      // [-π, +π]
            let pitch = m.attitude.pitch     // [-π/2, +π/2]

            // Map to screen axes based on current interface orientation so the effect
            // always feels like “looking through a window”.
            let orient = currentInterfaceOrientation()
            var screenX: Double
            var screenY: Double
            switch orient {
            case .portrait:
                screenX = -roll
                screenY =  pitch
            case .portraitUpsideDown:
                screenX =  roll
                screenY = -pitch
            case .landscapeLeft:
                screenX =  pitch
                screenY =  roll
            case .landscapeRight:
                screenX = -pitch
                screenY = -roll
            default:
                screenX = -roll
                screenY =  pitch
            }

            // --- Normalise by sensitivity (±degrees → ±1) ---
            let maxAngle = self.config.sensitivityDegrees * .pi / 180.0
            var xNorm = clamp(screenX / maxAngle, -1, 1)
            var yNorm = clamp(screenY / maxAngle, -1, 1)

            // --- Deadzone (recenter small jitters to 0) ---
            if self.config.deadzone > 0 {
                xNorm = applyDeadzone(xNorm, dz: self.config.deadzone)
                yNorm = applyDeadzone(yNorm, dz: self.config.deadzone)
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
                let alpha = 1 - exp(-dt / self.config.smoothingTau)
                if let sX = self.smoothedX { xNorm = sX + alpha * (xNorm - sX) }
                if let sY = self.smoothedY { yNorm = sY + alpha * (yNorm - sY) }
                self.smoothedX = xNorm
                self.smoothedY = yNorm
            }

            // --- Baseline (centre) handling ---
            if self.baselineOnNextSample || self.baselineX == nil || self.baselineY == nil {
                self.baselineX = xNorm
                self.baselineY = yNorm
                self.baselineOnNextSample = false
                let f3: (Double) -> String = { String(format: "%.3f", $0) }
                Diagnostics.log(.info, "Gyro baseline = (\(f3(xNorm)), \(f3(yNorm)))", category: "gyro")
            }

            let outX = clamp(xNorm - (self.baselineX ?? 0), -1, 1)
            let outY = clamp(yNorm - (self.baselineY ?? 0), -1, 1)

            // For compatibility with the rest of the app we still call these "yaw/pitch".
            self.sampleHandler?(outX, outY)
        }
    }

    func stop() {
        guard active else { return }
        active = false
        mgr.stopDeviceMotionUpdates()
        sampleHandler = nil
        errorHandler = nil
        lastTimestamp = nil
        smoothedX = nil
        smoothedY = nil
        baselineX = nil
        baselineY = nil
        baselineOnNextSample = false
    }
}

// MARK: - UI-facing provider (MainActor)

/// SwiftUI-friendly wrapper that holds published tilt values.
/// All state updates and logging happen on the main actor.
@MainActor
final class MotionTiltProvider: ObservableObject {

    @Published var yaw: Double = 0     // horizontal tilt (normalised)
    @Published var pitch: Double = 0   // vertical tilt (normalised)

    private let service = MotionTiltService()
    private var didLogFirstSample = false

    /// Current quality profile; initialised from the *current scene’s screen*.
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

        service.start(config: config) { [weak self] xNorm, yNorm in
            guard let self else { return }
            self.yaw = xNorm
            self.pitch = yNorm
            if !self.didLogFirstSample {
                self.didLogFirstSample = true
                let f3: (Double) -> String = { String(format: "%.3f", $0) }
                Diagnostics.log(.info, "First sample: x=\(f3(xNorm)) y=\(f3(yNorm)) (Hz=\(Int(self.config.hz)))", category: "gyro")
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

    /// Re-centre the parallax at the current device pose.
    func calibrateZero() {
        Diagnostics.log(.debug, "Gyro baseline reset requested", category: "gyro")
        service.requestBaselineReset()
    }

    /// Get the screen’s refresh rate from the foreground window scene’s screen.
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
            .first?.screen
        {
            let fps = anyScreen.maximumFramesPerSecond
            return fps > 0 ? Double(fps) : 60
        }
        return 60
    }
}
