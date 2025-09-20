//
//  DepthEstimator.swift
//  PhotoRevive3D
//
//  Created by . . on 9/19/25.
//

import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Builds a synthetic depth map (0…1, white = near) from a single image using
/// person segmentation when available, else a gentle radial fallback. Fully on-device.
enum DepthEstimator {

    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    struct Result {
        let depthCI: CIImage      // grayscale 0…1
        let personMaskCI: CIImage?// optional 0…1
        let size: CGSize
    }

    static func makeDepth(for uiImage: UIImage) throws -> Result {
        guard let cg = uiImage.cgImage else { throw EstimatorError.noCGImage }
        let size = CGSize(width: cg.width, height: cg.height)

        // Try person segmentation (best for portraits)
        let personMask = try? personSegmentationMask(cgImage: cg, targetSize: size)

        // Compose depth:
        // If we have a person mask, close small holes (max→min), then a light blur.
        // Otherwise, a soft radial near-centre map.
        let depth: CIImage
        if let personMask {
            let closed = personMask
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1.0])
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1.0])
                .clampedToExtent()
                .cropped(to: CGRect(origin: .zero, size: size))

            depth = closed
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3.0])
                .cropped(to: CGRect(origin: .zero, size: size))
        } else {
            depth = radialNearMap(size: size)
        }

        // Gentle smooth & clamp to 0…1
        let smoothed = depth
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0])
            .cropped(to: CGRect(origin: .zero, size: size))
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])

        return Result(depthCI: smoothed, personMaskCI: personMask, size: size)
    }

    // MARK: - Vision helpers

    private static func personSegmentationMask(cgImage: CGImage, targetSize: CGSize) throws -> CIImage {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let obs = request.results?.first as? VNPixelBufferObservation else {
            throw EstimatorError.noPersonMask
        }
        let mask = CIImage(cvPixelBuffer: obs.pixelBuffer)
        return mask.scaled(to: targetSize)
    }

    // MARK: - CI utilities

    /// Soft near-centre depth map as a safe fallback (white near, black far)
    private static func radialNearMap(size: CGSize) -> CIImage {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let grad = CIFilter.radialGradient()
        grad.center = centre
        grad.radius0 = Float(min(size.width, size.height) * 0.25)
        grad.radius1 = Float(min(size.width, size.height) * 0.9)
        grad.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1) // near
        grad.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1) // far
        return grad.outputImage!
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    enum EstimatorError: Error {
        case noCGImage, noPersonMask
    }
}

private extension CIImage {
    func scaled(to targetSize: CGSize) -> CIImage {
        let sx = targetSize.width / extent.width
        let sy = targetSize.height / extent.height
        return transformed(by: .init(scaleX: sx, y: sy))
    }
}
