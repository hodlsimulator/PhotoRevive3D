//  MotionTiltProvider.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import Foundation
@preconcurrency import CoreMotion
import Combine

/// Provides normalised tilt from CoreMotion for the preview (±1 over ~±30°).
/// Not actor-isolated; we hop to the main actor only where needed.
final class MotionTiltProvider: ObservableObject {
    private let mgr = CMMotionManager()

    // Background queue for CoreMotion callbacks.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.hodlsimulator.PhotoRevive3D.motion"
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = 1
        return q
    }()

    @Published var yaw: Double = 0      // write on main actor
    @Published var pitch: Double = 0    // write on main actor

    private var didLogFirstSample = false
    private var isActive = false        // read/write on main actor

    func start() {
        // Ensure we execute the body on the main actor.
        if !Thread.isMainThread {
            Task { @MainActor [weak self] in self?.start() }
            return
        }

        Diagnostics.log(.info, "Gyro start requested (available=\(mgr.isDeviceMotionAvailable))", category: "gyro")
        guard mgr.isDeviceMotionAvailable else {
            Diagnostics.log(.warn, "Device motion not available on this device/simulator", category: "gyro")
            return
        }
        guard !isActive else {
            Diagnostics.log(.debug, "Start ignored (already active)", category: "gyro")
            return
        }

        mgr.deviceMotionUpdateInterval = 1.0 / 15.0
        didLogFirstSample = false
        isActive = true
        Diagnostics.log(.info, "Device motion updates STARTED (.xArbitraryCorrectedZVertical @ 15Hz)", category: "gyro")

        // IMPORTANT: Do NOT capture `self` here; do all `self` work inside the inner main-actor hop.
        mgr.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { motion, error in
            if let error {
                Diagnostics.log(.error, "DeviceMotion handler error: \(error)", category: "gyro")
            }
            guard let m = motion else { return }

            // Compute off-main.
            let maxAngle = Double.pi / 6.0  // ±30°
            let yawNorm = max(-1, min(1, m.attitude.yaw   / maxAngle))
            let pitchNorm = max(-1, min(1, m.attitude.pitch / maxAngle))

            // Publish on the main actor (closure is @Sendable and main-isolated).
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isActive else { return }
                self.yaw = yawNorm
                self.pitch = pitchNorm

                if !self.didLogFirstSample {
                    self.didLogFirstSample = true
                    let f3: (Double) -> String = { String(format: "%.3f", $0) }
                    Diagnostics.log(
                        .info,
                        "First sample: yaw=\(f3(yawNorm)) pitch=\(f3(pitchNorm)) " +
                        "(raw yaw=\(f3(m.attitude.yaw)) pitch=\(f3(m.attitude.pitch)))",
                        category: "gyro"
                    )
                }
            }
        }
    }

    func stop() {
        if !Thread.isMainThread {
            Task { @MainActor [weak self] in self?.stop() }
            return
        }
        guard isActive || mgr.isDeviceMotionActive else {
            Diagnostics.log(.debug, "Stop ignored (not active)", category: "gyro")
            return
        }
        mgr.stopDeviceMotionUpdates()
        isActive = false
        Diagnostics.log(.info, "Device motion updates STOPPED", category: "gyro")
    }

    deinit {
        mgr.stopDeviceMotionUpdates()
        Diagnostics.log(.debug, "MotionTiltProvider deinit", category: "gyro")
    }
}
