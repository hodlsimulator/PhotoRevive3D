//  MotionTiltProvider.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import Foundation
@preconcurrency import CoreMotion
import Combine

// MARK: - Background service (no @MainActor)

/// Pure CoreMotion service that delivers callbacks on the main thread.
/// It computes normalized yaw/pitch in the handler (15 Hz is lightweight).
final class MotionTiltService {

    static var isAvailable: Bool { CMMotionManager().isDeviceMotionAvailable }

    private let mgr = CMMotionManager()
    private(set) var active = false

    // These closures are explicitly main-actor isolated.
    private var sampleHandler: (@MainActor (Double, Double) -> Void)?
    private var errorHandler: (@MainActor (Error) -> Void)?

    deinit {
        mgr.stopDeviceMotionUpdates()
    }

    /// Starts device motion and delivers *main-thread* callbacks.
    func start(
        onSample: @escaping @MainActor (Double, Double) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        guard !active, mgr.isDeviceMotionAvailable else { return }

        active = true
        sampleHandler = onSample
        errorHandler = onError

        mgr.deviceMotionUpdateInterval = 1.0 / 15.0

        // ✅ Run the CoreMotion handler on the MAIN operation queue to satisfy MainActor isolation.
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

            // Lightweight normalisation on main (15 Hz).
            let maxAngle = Double.pi / 6.0 // ±30°
            let yawNorm   = max(-1, min(1, m.attitude.yaw   / maxAngle))
            let pitchNorm = max(-1, min(1, m.attitude.pitch / maxAngle))

            self.sampleHandler?(yawNorm, pitchNorm)
        }
    }

    func stop() {
        guard active else { return }
        active = false
        mgr.stopDeviceMotionUpdates()
        sampleHandler = nil
        errorHandler = nil
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

    /// Start (idempotent from UI).
    func start() {
        Diagnostics.log(.info, "Gyro start requested (available=\(MotionTiltService.isAvailable))", category: "gyro")

        guard MotionTiltService.isAvailable else {
            Diagnostics.log(.warn, "Device motion not available on this device/simulator", category: "gyro")
            return
        }

        didLogFirstSample = false
        Diagnostics.log(.info, "Device motion updates STARTED (.xArbitraryCorrectedZVertical @ 15Hz)", category: "gyro")

        service.start { [weak self] yaw, pitch in
            guard let self else { return }

            // We are on main here.
            self.yaw = yaw
            self.pitch = pitch

            if !self.didLogFirstSample {
                self.didLogFirstSample = true
                let f3: (Double) -> String = { String(format: "%.3f", $0) }
                Diagnostics.log(
                    .info,
                    "First sample: yaw=\(f3(yaw)) pitch=\(f3(pitch))",
                    category: "gyro"
                )
            }
        } onError: { err in
            // Also on main.
            Diagnostics.log(.error, "DeviceMotion handler error: \(err)", category: "gyro")
        }
    }

    /// Stop (idempotent).
    func stop() {
        Diagnostics.log(.info, "Gyro STOP requested", category: "gyro")
        service.stop()
        Diagnostics.log(.info, "Device motion updates STOPPED", category: "gyro")
    }

    // No deinit needed; service cleans up its CMMotionManager.
}
