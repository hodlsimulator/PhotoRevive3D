//
//  VideoExporter.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import Foundation
import AVFoundation
import CoreImage
import UIKit

enum VideoExporter {

    enum ExportError: Error {
        case noPixelBufferPool
        case pixelBufferCreationFailed
        case writerFailed(Error?)
        case finishFailed(Error?)
    }

    /// Single shared CIContext for export work (perf).
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Renders a short parallax video and returns a temporary .mp4 URL.
    /// - Parameters:
    ///   - engine: Prepared `ParallaxEngine`.
    ///   - options: Duration/FPS/curve/intensity.
    ///   - onProgress: Optional progress callback 0...1 (hop to MainActor at call site if updating UI).
    static func exportParallaxVideo(
        engine: ParallaxEngine,
        options: ExportOptions,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {

        let seconds = max(0.5, options.seconds)
        let fps = max(1, options.fps)
        let totalFrames = max(1, Int(round(seconds * Double(fps))))

        // H.264 likes even dimensions.
        let w = Int(engine.outputSize.width.rounded()).evened()
        let h = Int(engine.outputSize.height.rounded()).evened()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoRevive3D-\(UUID().uuidString).mp4")

        // Writer + input
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: max(4_000_000, w * h * 4) // ~4 Mbps or scale with pixels
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: compression
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        precondition(writer.canAdd(input))
        writer.add(input)

        // Pixel buffer adaptor / pool
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: bufferAttrs
        )

        // Start session
        await MainActor.run {
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
        }

        guard let pool = adaptor.pixelBufferPool else {
            await MainActor.run { writer.cancelWriting() }
            throw ExportError.noPixelBufferPool
        }

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        var frameCount: Int64 = 0

        // Render loop — smooth ellipse over [0,1].
        do {
            for i in 0..<totalFrames {
                try Task.checkCancellation()

                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 1_000_000) // 1 ms
                    try Task.checkCancellation()
                }

                let tRaw = totalFrames > 1 ? Double(i) / Double(totalFrames - 1) : 0
                let t = options.curve.apply(tRaw)

                // Elliptical loop; values in [-1, 1].
                let theta = t * 2.0 * .pi
                let yaw = sin(theta) * 0.85
                let pitch = cos(theta) * 0.40

                let ci = engine.renderCI(
                    yaw: CGFloat(yaw),
                    pitch: CGFloat(pitch),
                    intensity: options.baseIntensity
                )

                var pxbufOpt: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pxbufOpt)
                guard let pxbuf = pxbufOpt else { throw ExportError.pixelBufferCreationFailed }

                // Render CI → PixelBuffer
                Self.ciContext.render(ci, to: pxbuf)

                let time = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))
                adaptor.append(pxbuf, withPresentationTime: time)
                frameCount += 1

                if let onProgress {
                    onProgress(Double(i + 1) / Double(totalFrames))
                }
            }
        } catch {
            // Cancellation or error: best-effort cleanup.
            input.markAsFinished()
            await MainActor.run { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            if error is CancellationError {
                throw error
            } else {
                throw ExportError.writerFailed(error)
            }
        }

        input.markAsFinished()

        // Finish writing on the main actor; don't touch `writer` inside the @Sendable completion.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                writer.finishWriting {
                    cont.resume(returning: ())
                }
            }
        }

        // Now safely read status/error on the main actor.
        let status = await MainActor.run { writer.status }
        switch status {
        case .completed:
            return url
        case .failed, .cancelled, .unknown, .writing:
            let err = await MainActor.run { writer.error }
            throw ExportError.finishFailed(err)
        @unknown default:
            let err = await MainActor.run { writer.error }
            throw ExportError.finishFailed(err)
        }
    }
}

// MARK: - Utilities

private extension Int {
    func evened() -> Int { self % 2 == 0 ? self : self - 1 }
}
