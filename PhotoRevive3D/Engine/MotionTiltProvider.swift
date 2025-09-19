//  MotionTiltProvider.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import Foundation
@preconcurrency import CoreMotion
import Combine

@MainActor
final class MotionTiltProvider: ObservableObject {
    private let mgr = CMMotionManager()

    // Background queue for sensor callbacks.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.hodlsimulator.PhotoRevive3D.motion"
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = 1
        return q
    }()

    @Published var yaw: Double = 0
    @Published var pitch: Double = 0

    private var didLogFirstSample = false
    private var isActive = false

    func start() {
        Diagnostics.log(.info, "Gyro start requested (available=\(mgr.isDeviceMotionAvailable))", category: "gyro")

        guard mgr.isDeviceMotionAvailable else {
            Diagnostics.log(.warn, "Device motion not available on this device/simulator", category: "gyro")
            return
        }
        guard !isActive else {
            Diagnostics.log(.debug, "Start ignored (already active)", category: "gyro")
            return
        }

        // Lower rate to reduce churn during preview.
        mgr.deviceMotionUpdateInterval = 1.0 / 15.0
        didLogFirstSample = false

        mgr.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { [weak self] motion, error in
            if let error {
                Diagnostics.log(.error, "DeviceMotion handler error: \(error)", category: "gyro")
            }
            guard let m = motion else { return }

            // Compute off-main
            let maxAngle = Double.pi / 6.0 // ±30°
            let yawNorm = max(-1, min(1, m.attitude.yaw / maxAngle))
            let pitchNorm = max(-1, min(1, m.attitude.pitch / maxAngle))

            // Hop to the main actor BEFORE touching `self` (actor isolation).
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.yaw = yawNorm
                self.pitch = pitchNorm

                if !self.didLogFirstSample {
                    self.didLogFirstSample = true
                    Diagnostics.log(
                        .info,
                        String(format: "First sample: yaw=%.3f pitch=%.3f (raw yaw=%.3f pitch=%.3f)",
                               yawNorm, pitchNorm, m.attitude.yaw, m.attitude.pitch),
                        category: "gyro"
                    )
                }
            }
        }

        isActive = true
        Diagnostics.log(.info, "Device motion updates STARTED (.xArbitraryCorrectedZVertical @ 15Hz)", category: "gyro")
    }

    func stop() {
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
