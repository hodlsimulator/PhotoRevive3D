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
/// Full-res for export; downscaled pipeline for live preview.
final class ParallaxEngine {
    private(set) var originalCI: CIImage
    private(set) var depthCI: CIImage!
    private(set) var personMaskCI: CIImage?

    /// CIContext for both preview + export
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Full-resolution output (used by exporter)
    private(set) var outputSize: CGSize
    var outputAspect: CGFloat { outputSize.width / outputSize.height }

    // Precomputed full-res layers
    private var bgCI: CIImage!
    private var fgCI: CIImage!
    private var maskCI: CIImage!

    // Downscaled preview pipeline to keep interactive rendering light
    private let previewLongest: CGFloat = 1600 // longest edge in px for live preview
    private var previewScale: CGFloat = 1
    private var previewSize: CGSize = .zero
    private var pBgCI: CIImage!
    private var pFgCI: CIImage!

    init(image uiImage: UIImage) {
        if let cg = uiImage.cgImage {
            self.originalCI = CIImage(cgImage: cg)
        } else if let ci = uiImage.ciImage {
            self.originalCI = ci
        } else {
            self.originalCI = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        self.outputSize = originalCI.extent.size
    }

    /// Must be called once after init.
    @MainActor
    func prepare() async throws {
        // Build synthetic depth + (optional) person mask
        let ui = UIImage(from: originalCI, context: ciContext)
        let depthRes = try DepthEstimator.makeDepth(for: ui)
        self.depthCI = depthRes.depthCI
        self.personMaskCI = depthRes.personMaskCI

        // If no person mask, derive a soft mask from the nearest depth
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
        let slightlyScaledBG = originalCI
            .transformed(by: .init(scaleX: 1.03, y: 1.03))
            .transformed(by: .init(translationX: -originalCI.extent.width * 0.015,
                                   y: -originalCI.extent.height * 0.015))
            .cropped(to: originalCI.extent)
        bgCI = slightlyScaledBG.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: invMask
        ])

        // Prepare downscaled preview layers
        let longEdge = max(outputSize.width, outputSize.height)
        previewScale = min(1, previewLongest / longEdge)
        if previewScale < 1 {
            let pOriginal = lanczosScale(originalCI, scale: previewScale)
            let pMask = lanczosScale(maskCI, scale: previewScale)
            let pTransparent = CIImage(color: .clear).cropped(to: pOriginal.extent)

            // Preview foreground/background (mirrors full-res logic in preview pixel space)
            pFgCI = pOriginal.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: pTransparent,
                kCIInputMaskImageKey: pMask
            ])

            let pInvMask = pMask.applyingFilter("CIColorInvert")
            let pSlight = pOriginal
                .transformed(by: .init(scaleX: 1.03, y: 1.03))
                .transformed(by: .init(translationX: -pOriginal.extent.width * 0.015,
                                       y: -pOriginal.extent.height * 0.015))
                .cropped(to: pOriginal.extent)
            pBgCI = pSlight.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: pTransparent,
                kCIInputMaskImageKey: pInvMask
            ])

            previewSize = pOriginal.extent.size
        } else {
            // No downscale needed
            previewScale = 1
            previewSize = outputSize
            pBgCI = bgCI
            pFgCI = fgCI
        }
    }

    // MARK: - Preview rendering (downscaled)

    func renderPreviewUIImage(yaw: CGFloat, pitch: CGFloat, intensity: CGFloat) -> UIImage? {
        let ci = renderPreviewCI(yaw: yaw, pitch: pitch, intensity: intensity)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    func renderPreviewCI(yaw: CGFloat, pitch: CGFloat, intensity: CGFloat) -> CIImage {
        let maxShift = min(previewSize.width, previewSize.height) * 0.02 * intensity // ≈2% of min dimension
        let bgTx = yaw * maxShift
        let bgTy = pitch * maxShift
        let fgTx = -yaw * maxShift * 0.65
        let fgTy = -pitch * maxShift * 0.65

        let bg = pBgCI
            .transformed(by: .init(translationX: bgTx, y: bgTy))
            .transformed(by: .init(scaleX: 1.01, y: 1.01))
            .cropped(to: pBgCI.extent)

        let fg = pFgCI
            .transformed(by: .init(translationX: fgTx, y: fgTy))
            .transformed(by: .init(scaleX: 1.005, y: 1.005))
            .cropped(to: pFgCI.extent)

        return fg.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: bg])
    }

    // MARK: - Full-resolution rendering (export)

    /// CIImage render variant used by VideoExporter; stays full-res.
    func renderCI(yaw: CGFloat, pitch: CGFloat, intensity: CGFloat) -> CIImage {
        let maxShift = min(outputSize.width, outputSize.height) * 0.02 * intensity
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

    private func lanczosScale(_ image: CIImage, scale: CGFloat) -> CIImage {
        image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1.0
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
