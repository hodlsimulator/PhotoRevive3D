//
//  MotionTiltProvider.swift
//  PhotoRevive3D
//
//  Created by . . on 9/19/25.
//

import Foundation
import CoreMotion
import Combine

/// Very small CoreMotion helper that exposes yaw/pitch in [-1, 1].
final class MotionTiltProvider: ObservableObject {
    private let mgr = CMMotionManager()
    private let queue = OperationQueue()
    @Published var yaw: Double = 0
    @Published var pitch: Double = 0

    func start() {
        guard mgr.isDeviceMotionAvailable else { return }
        mgr.deviceMotionUpdateInterval = 1.0 / 60.0
        mgr.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            // Map small angles to [-1, 1] with clamping
            let maxAngle: Double = .pi / 6.0 // ±30°
            let yawNorm = max(-1, min(1, m.attitude.yaw / maxAngle))
            let pitchNorm = max(-1, min(1, m.attitude.pitch / maxAngle))
            DispatchQueue.main.async {
                self.yaw = yawNorm
                self.pitch = pitchNorm
            }
        }
    }

    func stop() {
        mgr.stopDeviceMotionUpdates()
    }
}

