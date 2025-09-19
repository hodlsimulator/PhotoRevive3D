//
//  VideoExporter.swift
//  PhotoRevive3D
//
//  Created by . . on 9/19/25.
//

import Foundation
import AVFoundation
import CoreImage
import UIKit

enum VideoExporter {
    /// Renders a short parallax “yoyo” video and returns a temporary .mp4 URL.
    static func exportParallaxVideo(
        engine: ParallaxEngine,
        seconds: Double,
        fps: Int,
        baseIntensity: CGFloat
    ) async throws -> URL {
        let frames = max(1, Int(round(seconds * Double(fps))))
        let size = engine.outputSize

        // Output URL
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoRevive3D-\(UUID().uuidString).mp4")

        // Writer
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width.rounded()),
            AVVideoHeightKey: Int(size.height.rounded()),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, Int(size.width * size.height * 4)) // ~4Mbps or more
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: Int(size.width.rounded()),
            kCVPixelBufferHeightKey as String: Int(size.height.rounded())
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: attrs)
        precondition(writer.canAdd(input))
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var frameCount: Int64 = 0
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        // Render loop
        let context = CIContext(options: [.useSoftwareRenderer: false])
        for i in 0..<frames {
            // Yoyo motion: 0→1→0 over the clip
            let t = Double(i) / Double(max(frames - 1, 1))
            let phase = (t <= 0.5) ? (t * 2.0) : (2.0 - t * 2.0) // up then down
            let yaw = CGFloat(sin(phase * .pi))                   // smooth ease
            let pitch = CGFloat(cos(phase * .pi * 0.5) - 1.0)     // subtle secondary axis
            let frameCI = engine.renderCI(yaw: yaw, pitch: pitch, intensity: baseIntensity)

            // Create pixel buffer and render
            var pbOpt: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                             Int(size.width), Int(size.height),
                                             kCVPixelFormatType_32BGRA,
                                             attrs as CFDictionary,
                                             &pbOpt)
            guard status == kCVReturnSuccess, let pb = pbOpt else {
                throw ExportError.pixelBufferCreateFailed(status: status)
            }
            CVPixelBufferLockBaseAddress(pb, [])
            context.render(frameCI, to: pb)
            CVPixelBufferUnlockBaseAddress(pb, [])

            // Append
            let time = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000) // 2 ms (Swift 6-safe)
            }
            adaptor.append(pb, withPresentationTime: time)
            frameCount += 1
        }

        input.markAsFinished()
        try await finish(writer: writer)
        return url
    }

    private static func finish(writer: AVAssetWriter) async throws {
        await withCheckedContinuation { cont in
            writer.finishWriting {
                cont.resume()
            }
        }
        if writer.status != .completed {
            throw writer.error ?? ExportError.writerFailed
        }
    }

    enum ExportError: Error {
        case writerFailed
        case pixelBufferCreateFailed(status: CVReturn)
    }
}
