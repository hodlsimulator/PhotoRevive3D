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
        return q
    }()

    @Published var yaw: Double = 0
    @Published var pitch: Double = 0

    func start() {
        guard mgr.isDeviceMotionAvailable else { return }
        mgr.deviceMotionUpdateInterval = 1.0 / 60.0

        // IMPORTANT: Don’t touch `self` off the main actor.
        mgr.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { [weak self] motion, _ in
            guard let m = motion else { return }

            // Map small angles to [-1, 1] with clamping
            let maxAngle = Double.pi / 6.0 // ±30°
            let yawNorm = max(-1, min(1, m.attitude.yaw / maxAngle))
            let pitchNorm = max(-1, min(1, m.attitude.pitch / maxAngle))

            // Hop to the main actor before touching the observable object.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.yaw = yawNorm
                self.pitch = pitchNorm
            }
        }
    }

    func stop() {
        mgr.stopDeviceMotionUpdates()
    }
}
