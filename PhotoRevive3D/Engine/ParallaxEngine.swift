//
//  ParallaxEngine.swift
//  PhotoRevive3D
//
//  Created by . . on 9/19/25.
//

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Renders a 2-layer parallax (background vs subject) using the depth/mask.
/// Fully on-device; no external dependencies.
final class ParallaxEngine {
    private(set) var originalCI: CIImage
    private(set) var depthCI: CIImage!
    private(set) var personMaskCI: CIImage?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private(set) var outputSize: CGSize
    var outputAspect: CGFloat { outputSize.width / outputSize.height }

    // Precomputed layers
    private var bgCI: CIImage!
    private var fgCI: CIImage!
    private var maskCI: CIImage!

    init(image uiImage: UIImage) {
        // Normalise to CIImage in sRGB
        if let cg = uiImage.cgImage {
            self.originalCI = CIImage(cgImage: cg)
        } else if let ci = uiImage.ciImage {
            self.originalCI = ci
        } else {
            self.originalCI = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        self.outputSize = originalCI.extent.size
    }

    /// Must be called once after init. Performs segmentation+layer prep.
    @MainActor
    func prepare() async throws {
        // Build synthetic depth + (optional) person mask
        let ui = UIImage(from: originalCI, context: ciContext)
        let depthRes = try DepthEstimator.makeDepth(for: ui)
        self.depthCI = depthRes.depthCI
        self.personMaskCI = depthRes.personMaskCI

        // If no person mask, derive a soft mask from the brightest (nearest) depth
        let subjectMask: CIImage = personMaskCI ?? depthThreshold(depthCI, threshold: 0.6)

        // Slightly expand mask to soften edges
        let softMask = subjectMask
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5.0])
            .cropped(to: originalCI.extent)

        self.maskCI = clamp01(softMask)

        // Foreground = image over transparent using mask
        let transparent = CIImage(color: .clear).cropped(to: originalCI.extent)
        fgCI = originalCI.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: maskCI as Any
        ])

        // Background = image over transparent using inverted mask, upscaled a touch to reduce edge gaps
        let invMask = maskCI.applyingFilter("CIColorInvert")
        let slightlyScaledBG = originalCI.transformed(by: .init(scaleX: 1.03, y: 1.03))
            .transformed(by: .init(translationX: -originalCI.extent.width * 0.015,
                                   y: -originalCI.extent.height * 0.015))
            .cropped(to: originalCI.extent)

        bgCI = slightlyScaledBG.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: invMask
        ])
    }

    /// Render a frame image from yaw/pitch in [-1,1] and intensity in [0.2,1.0].
    func renderUIImage(yaw: CGFloat, pitch: CGFloat, intensity: CGFloat) -> UIImage? {
        let ci = renderCI(yaw: yaw, pitch: pitch, intensity: intensity)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// CIImage render variant (used by VideoExporter)
    func renderCI(yaw: CGFloat, pitch: CGFloat, intensity: CGFloat) -> CIImage {
        // Translate background and foreground in opposite directions; small scale to reduce edge exposure
        let maxShift = min(outputSize.width, outputSize.height) * 0.02 * intensity // ≈2% of min dimension
        let bgTx = yaw * maxShift
        let bgTy = pitch * maxShift
        let fgTx = -yaw * maxShift * 0.65
        let fgTy = -pitch * maxShift * 0.65

        let bg = bgCI
            .transformed(by: .init(translationX: bgTx, y: bgTy))
            .transformed(by: .init(scaleX: 1.01, y: 1.01))
            .cropped(to: originalCI.extent)

        let fg = fgCI
            .transformed(by: .init(translationX: fgTx, y: fgTy))
            .transformed(by: .init(scaleX: 1.005, y: 1.005))
            .cropped(to: originalCI.extent)

        // Composite fg over bg
        return fg.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: bg])
    }

    // MARK: - Helpers

    private func depthThreshold(_ depth: CIImage, threshold: CGFloat) -> CIImage {
        // Convert grayscale to alpha via thresholding
        let params: [String: Any] = [
            "inputMinComponents": CIVector(x: threshold, y: threshold, z: threshold, w: threshold),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ]
        let clamped = depth.applyingFilter("CIColorClamp", parameters: params)
        // Normalise to 0…1 again
        return clamped.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -2 * threshold, y: -2 * threshold, z: -2 * threshold, w: 0)
        ])
    }

    private func clamp01(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
    }
}

private extension UIImage {
    convenience init(from ci: CIImage, context: CIContext) {
        let rect = ci.extent
        let cg = context.createCGImage(ci, from: rect)!
        self.init(cgImage: cg, scale: 1, orientation: .up)
    }
}
