//
//  ExportOptions.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import Foundation
import CoreGraphics

/// Options controlling video export.
public struct ExportOptions: Sendable, Equatable {
    public var seconds: Double           // 2...8 in UI
    public var fps: Int                  // 24/30/60
    public var baseIntensity: CGFloat    // 0.2...1.0 (from the UI slider)
    public var curve: MotionCurve        // how motion progresses over time

    public init(seconds: Double, fps: Int, baseIntensity: CGFloat, curve: MotionCurve) {
        self.seconds = seconds
        self.fps = fps
        self.baseIntensity = baseIntensity
        self.curve = curve
    }

    public enum MotionCurve: String, CaseIterable, Sendable {
        case linear
        case easeInOut

        /// Maps t∈[0,1] → [0,1]
        public func apply(_ t: Double) -> Double {
            switch self {
            case .linear:
                return t
            case .easeInOut:
                // Smoothstep (cubic) — gentle start/stop
                return t * t * (3 - 2 * t)
            }
        }
    }
}
