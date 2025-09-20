//
//  ParallaxEngine.swift
//  PhotoRevive3D
//
//  Created by . . on 9/19/25.
//
//  Depth-driven multi-slice parallax (no deprecated CI kernels).
//  Foreground moves more (opposite direction), background moves less.
//  Uses overscan + feathered/dilated band masks to avoid edge seams.
//

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

final class ParallaxEngine {

    // MARK: - Tuning

    /// Max per-axis travel as a fraction of the *shorter* image edge at intensity == 1.0.
    /// 0.08 ≈ ±8% → bold, Spatial-Scenes-like swing.
    private let travelFractionAtFullIntensity: CGFloat = 0.08

    /// Extra overscan to hide edges at large tilts.
    private let overscanSafety: CGFloat = 0.02

    /// Number of depth bands (more = smoother, slower). 6–10 is a good range.
    private let bandCount: Int = 8

    /// Band feather width in depth units (0…1). Larger → softer band edges.
    private let bandFeather: CGFloat = 0.15

    /// Dilate masks a hair to hide inter-band seams when bands move differently.
    private let maskDilateRadius: CGFloat = 1.0

    /// Optional extra pop for nearest band (1 = linear).
    private let nearExponent: CGFloat = 1.15

    // MARK: - Inputs & CI setup

    private(set) var originalCI: CIImage
    private(set) var depthCI: CIImage!      // grayscale 0…1 (white = near)

    private let ciContext: CIContext = {
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let outCS  = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates:  false,
            .workingColorSpace:   linear,
            .outputColorSpace:    outCS
        ])
    }()

    // Full-resolution output
    private(set) var outputSize: CGSize
    var outputAspect: CGFloat { outputSize.width / outputSize.height }

    // Overscanned source for “look-around” sampling (finite extent, larger than photo)
    private var overscannedSrcCI: CIImage!

    // Screen-scaled preview pipeline
    private(set) var previewTargetLongest: CGFloat = 1600 // px; updated by updatePreviewLOD
    private var previewScale: CGFloat = 1
    private var pDepth: CIImage!
    private var pSrc: CIImage!
    private var previewSize: CGSize = .zero

    // MARK: - Init

    init(image uiImage: UIImage) {
        if let cg = uiImage.cgImage {
            self.originalCI = CIImage(cgImage: cg)
        } else if let ci = uiImage.ciImage {
            self.originalCI = ci
        } else {
            self.originalCI = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
                .cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        self.outputSize = originalCI.extent.size
    }

    /// Must be called once after init.
    @MainActor
    func prepare() async throws {
        // Build synthetic depth (0…1, white=near) entirely on-device.
        let ui = UIImage(from: originalCI, context: ciContext)
        let depthRes = try DepthEstimator.makeDepth(for: ui)

        // Normalise and **resize depth to exactly match the photo**.
        let depthRaw = clamp01(depthRes.depthCI)
        depthCI = resizeTo(depthRaw, target: originalCI.extent.size)

        // Overscanned source (finite extent, larger than original) for export rendering.
        let overscanScale = 1.0 + 2.0 * (travelFractionAtFullIntensity + overscanSafety)
        let w = originalCI.extent.width
        let h = originalCI.extent.height
        let dx = -(w * (overscanScale - 1) * 0.5)
        let dy = -(h * (overscanScale - 1) * 0.5)
        overscannedSrcCI = originalCI
            .transformed(by: .init(scaleX: overscanScale, y: overscanScale))
            .transformed(by: .init(translationX: dx, y: dy)) // NOTE: no clampedToExtent() here

        rebuildPreviewLayers(targetLongestPx: previewTargetLongest)
        Diagnostics.log(.info, "ParallaxEngine prepared (size=\(Int(outputSize.width))x\(Int(outputSize.height)))", category: "engine")
    }

    /// Update preview LOD to match on-screen pixel size.
    @MainActor
    func updatePreviewLOD(targetLongestPx: CGFloat) {
        let quantised = max(256, (targetLongestPx / 64).rounded() * 64)
        if abs(quantised - previewTargetLongest) > 32 {
            previewTargetLongest = quantised
            rebuildPreviewLayers(targetLongestPx: quantised)
        }
    }

    // MARK: - Preview snapshot (thread-safe to *use* off-main)

    struct PreviewSnapshot: @unchecked Sendable {
        let src: CIImage      // overscanned, **finite extent**, larger than frame
        let depth: CIImage    // 0…1, **same size** as size
        let size: CGSize      // destination frame size
        let travelFraction: CGFloat
        let bands: Int
        let feather: CGFloat
        let dilateRadius: CGFloat
        let nearExp: CGFloat
    }

    /// Capture immutable inputs for one preview composition.
    @MainActor
    func makePreviewSnapshot() -> PreviewSnapshot? {
        guard let pSrc, let pDepth else { return nil }
        return PreviewSnapshot(
            src: pSrc,
            depth: pDepth,
            size: previewSize,
            travelFraction: travelFractionAtFullIntensity,
            bands: bandCount,
            feather: bandFeather,
            dilateRadius: maskDilateRadius,
            nearExp: nearExponent
        )
    }

    // MARK: - Composition

    /// Pure function: compose a preview CIImage from a snapshot + params.
    nonisolated
    static func composePreview(from snap: PreviewSnapshot,
                               yaw: CGFloat,
                               pitch: CGFloat,
                               intensity: CGFloat) -> CIImage
    {
        let travel = min(snap.size.width, snap.size.height)
                   * snap.travelFraction
                   * max(0, intensity)

        let kx = yaw   * travel
        let ky = pitch * travel

        let outExtent = CGRect(origin: .zero, size: snap.size)

        // Local helper – builds a feathered, dilated band mask (exactly outExtent size).
        @inline(__always)
        func bandMask(depth: CIImage,
                      targetExtent: CGRect,
                      lower: CGFloat,
                      upper: CGFloat,
                      feather: CGFloat,
                      dilateRadius: CGFloat) -> CIImage
        {
            let eps = max(0.0001, feather)

            let up = depth.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector":    CIVector(x: 1/eps, y: 0, z: 0, w: 0),
                "inputGVector":    CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector":    CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector":    CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -lower/eps, y: -lower/eps, z: -lower/eps, w: 0)
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])

            let down = depth.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector":    CIVector(x: -1/eps, y: 0, z: 0, w: 0),
                "inputGVector":    CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector":    CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector":    CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x:  upper/eps, y:  upper/eps, z:  upper/eps, w: 0)
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])

            let band = up.applyingFilter("CIMinimumCompositing", parameters: [
                kCIInputBackgroundImageKey: down
            ])

            let blurred = band
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.5, eps * 10)])
                .cropped(to: depth.extent)

            let dilated = blurred.applyingFilter("CIMorphologyMaximum", parameters: [
                kCIInputRadiusKey: max(0, dilateRadius)
            ])

            return dilated
                .applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
                ])
                .transformed(by: .identity)
                .cropped(to: targetExtent)
        }

        // Start with the unshifted base so you always see content.
        var acc = snap.src.cropped(to: outExtent)

        // Compose back-to-front: far → near, replacing masked regions each pass.
        for i in 0..<snap.bands {
            let a = CGFloat(i) / CGFloat(snap.bands)
            let b = CGFloat(i + 1) / CGFloat(snap.bands)
            let mid = (a + b) * 0.5

            // Motion weight: far(+1) … mid(0) … near(−1), with a touch more for near.
            let signed = (0.5 - mid) * 2.0
            let sgn: CGFloat = (signed == 0) ? 0 : (signed > 0 ? 1 : -1)
            let w = sgn * pow(abs(signed), max(snap.nearExp, 1.0))

            let dx = kx * w
            let dy = ky * w

            let mask = bandMask(depth: snap.depth,
                                targetExtent: outExtent,
                                lower: a,
                                upper: b,
                                feather: snap.feather,
                                dilateRadius: snap.dilateRadius)

            let shifted = snap.src
                .transformed(by: .init(translationX: dx, y: dy))
                .cropped(to: outExtent)

            acc = shifted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: acc,
                kCIInputMaskImageKey:       mask
            ])
        }

        return acc
    }

    // MARK: - Full-resolution rendering (export)

    func renderCI(yaw: CGFloat, pitch: CGFloat, intensity: CGFloat) -> CIImage {
        let travel = min(outputSize.width, outputSize.height)
                   * travelFractionAtFullIntensity
                   * max(0, intensity)

        let kx = yaw   * travel
        let ky = pitch * travel

        let outExtent = originalCI.extent

        @inline(__always)
        func bandMask(depth: CIImage,
                      targetExtent: CGRect,
                      lower: CGFloat,
                      upper: CGFloat,
                      feather: CGFloat,
                      dilateRadius: CGFloat) -> CIImage
        {
            let eps = max(0.0001, feather)

            let up = depth.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector":    CIVector(x: 1/eps, y: 0, z: 0, w: 0),
                "inputGVector":    CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector":    CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector":    CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -lower/eps, y: -lower/eps, z: -lower/eps, w: 0)
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])

            let down = depth.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector":    CIVector(x: -1/eps, y: 0, z: 0, w: 0),
                "inputGVector":    CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector":    CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector":    CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x:  upper/eps, y:  upper/eps, z:  upper/eps, w: 0)
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])

            let band = up.applyingFilter("CIMinimumCompositing", parameters: [
                kCIInputBackgroundImageKey: down
            ])

            let blurred = band
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.5, eps * 10)])
                .cropped(to: depth.extent)

            let dilated = blurred.applyingFilter("CIMorphologyMaximum", parameters: [
                kCIInputRadiusKey: max(0, dilateRadius)
            ])

            return dilated
                .applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
                ])
                .transformed(by: .identity)
                .cropped(to: targetExtent)
        }

        // Base (unshifted) so there’s always visible output.
        var acc = overscannedSrcCI.cropped(to: outExtent)

        for i in 0..<bandCount {
            let a = CGFloat(i) / CGFloat(bandCount)
            let b = CGFloat(i + 1) / CGFloat(bandCount)
            let mid = (a + b) * 0.5

            let signed = (0.5 - mid) * 2.0
            let sgn: CGFloat = (signed == 0) ? 0 : (signed > 0 ? 1 : -1)
            let w = sgn * pow(abs(signed), max(nearExponent, 1.0))

            let dx = kx * w
            let dy = ky * w

            let mask = bandMask(depth: depthCI,
                                targetExtent: outExtent,
                                lower: a,
                                upper: b,
                                feather: bandFeather,
                                dilateRadius: maskDilateRadius)

            let shifted = overscannedSrcCI
                .transformed(by: .init(translationX: dx, y: dy))
                .cropped(to: outExtent)

            acc = shifted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: acc,
                kCIInputMaskImageKey:       mask
            ])
        }

        return acc.cropped(to: outExtent)
    }

    // MARK: - Helpers

    @MainActor
    private func rebuildPreviewLayers(targetLongestPx: CGFloat) {
        let longEdge = max(outputSize.width, outputSize.height)
        let newScale = min(1, targetLongestPx / longEdge)
        if abs(newScale - previewScale) < 0.04, pSrc != nil, pDepth != nil {
            return
        }

        previewScale = newScale

        // Build finite-extent overscanned **preview** sources derived from scaled originals.
        let overscanScale = 1.0 + 2.0 * (travelFractionAtFullIntensity + overscanSafety)

        if previewScale < 1 {
            // Downscale originals isotropically.
            let pOriginal = lanczosScale(originalCI, scale: previewScale)
            let pDepthRaw = lanczosScale(depthCI,    scale: previewScale)

            // Overscan the scaled original (finite extent, larger than pOriginal).
            let w = pOriginal.extent.width
            let h = pOriginal.extent.height
            let dx = -(w * (overscanScale - 1) * 0.5)
            let dy = -(h * (overscanScale - 1) * 0.5)
            let pOverscanned = pOriginal
                .transformed(by: .init(scaleX: overscanScale, y: overscanScale))
                .transformed(by: .init(translationX: dx, y: dy))

            pSrc = pOverscanned
            pDepth = pDepthRaw
            previewSize = pOriginal.extent.size
        } else {
            // 1:1 preview
            pSrc = overscannedSrcCI
            pDepth = depthCI
            previewSize = outputSize
        }
    }

    private func clamp01(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
    }

    /// Anisotropic resize to a target size (for depth).
    private func resizeTo(_ image: CIImage, target: CGSize) -> CIImage {
        let sx = target.width  / max(1, image.extent.width)
        let sy = target.height / max(1, image.extent.height)
        return image
            .transformed(by: .init(scaleX: sx, y: sy))
            .cropped(to: CGRect(origin: .zero, size: target))
    }

    private func lanczosScale(_ image: CIImage, scale: CGFloat) -> CIImage {
        image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey:        scale,
            kCIInputAspectRatioKey:  1.0
        ])
    }
}

// MARK: - UIImage bridge

private extension UIImage {
    convenience init(from ci: CIImage, context: CIContext) {
        let rect = ci.extent
        let cg = context.createCGImage(ci, from: rect)!
        self.init(cgImage: cg, scale: 1, orientation: .up)
    }
}
