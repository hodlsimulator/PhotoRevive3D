//
//  CIRenderView.swift
//  PhotoRevive3D
//
//  Created by . . on 9/19/25.
//
//  SwiftUI wrapper that renders CIImage frames directly into an MTKView.
//  Uses a command buffer (no per-frame CGImage allocations).
//

import SwiftUI
import MetalKit
import CoreImage

struct CIRenderView: UIViewRepresentable {
    @Binding var image: CIImage?

    final class Coordinator: NSObject, MTKViewDelegate {
        private var ciContext: CIContext?
        private var commandQueue: MTLCommandQueue?
        private let colorSpace = CGColorSpaceCreateDeviceRGB()
        var currentImage: CIImage?

        private func ensureMetal(for view: MTKView) {
            if view.device == nil {
                view.device = MTLCreateSystemDefaultDevice()
            }
            if let dev = view.device {
                if commandQueue == nil { commandQueue = dev.makeCommandQueue() }
                if ciContext == nil {
                    ciContext = CIContext(mtlDevice: dev, options: [.cacheIntermediates: false])
                }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

        func draw(in view: MTKView) {
            guard let img = currentImage else { return }
            ensureMetal(for: view)
            guard
                let ciContext = ciContext,
                let commandQueue = commandQueue,
                let drawable = view.currentDrawable
            else { return }

            // Aspect-fit destination rect in drawable pixels
            let iw = img.extent.width, ih = img.extent.height
            let vw = view.drawableSize.width, vh = view.drawableSize.height
            guard iw > 0, ih > 0, vw > 0, vh > 0 else { return }

            let scale = min(vw / iw, vh / ih)
            let w = iw * scale, h = ih * scale
            let x = (vw - w) * 0.5, y = (vh - h) * 0.5
            let dest = CGRect(x: x, y: y, width: w, height: h)

            autoreleasepool {
                if let cb = commandQueue.makeCommandBuffer() {
                    ciContext.render(
                        img,
                        to: drawable.texture,
                        commandBuffer: cb,
                        bounds: dest,
                        colorSpace: colorSpace
                    )
                    cb.present(drawable)
                    cb.commit()
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isPaused = true                   // draw only when asked
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = false           // required for Core Image rendering
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.currentImage = image
        uiView.setNeedsDisplay()
    }
}
