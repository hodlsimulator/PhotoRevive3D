//
//  ContentView.swift
//  PhotoRevive3D
//
//  Created by . . on 9/19/25.
//

import SwiftUI
import PhotosUI
import CoreMotion

struct ContentView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var originalImage: UIImage?
    @State private var engine: ParallaxEngine?
    @State private var preparing = false
    @State private var yaw: CGFloat = 0.0
    @State private var pitch: CGFloat = 0.0
    @State private var intensity: CGFloat = 0.6
    @State private var useMotion = false
    @State private var shareSheet: ShareSheet?
    @StateObject private var motion = MotionTiltProvider()

    var body: some View {
        VStack(spacing: 16) {
            headerBar

            Group {
                if let engine {
                    ParallaxPreview(engine: engine,
                                    yaw: useMotion ? CGFloat(motion.yaw) : yaw,
                                    pitch: useMotion ? CGFloat(motion.pitch) : pitch,
                                    intensity: intensity)
                        .aspectRatio(engine.outputAspect, contentMode: .fit)
                        .glassCard()
                        .animation(.easeInOut(duration: 0.15), value: yaw)
                        .animation(.easeInOut(duration: 0.15), value: pitch)
                } else {
                    placeholderCard
                }
            }
            .padding(.horizontal)

            controlsBar
                .padding(.horizontal)
        }
        .sheet(item: $shareSheet) { sheet in
            sheet
        }
        .onChange(of: pickerItem) { _, newItem in
            Task { await loadImage(item: newItem) }
        }
        .onChange(of: useMotion) { _, enabled in
            if enabled { motion.start() } else { motion.stop() }
        }
    }

    private var headerBar: some View {
        HStack {
            Text("PhotoRevive 3D")
                .font(.title2.weight(.bold))
            Spacer()
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Pick Photo", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private var placeholderCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.artframe")
                .resizable()
                .scaledToFit()
                .frame(width: 80)
                .foregroundStyle(.secondary)
            Text("Pick a photo to begin")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .glassCard()
    }

    private var controlsBar: some View {
        VStack(spacing: 12) {
            if engine != nil {
                HStack {
                    Toggle(isOn: $useMotion) { Label("Gyro", systemImage: "gyroscope") }
                        .toggleStyle(.switch)
                    Spacer()
                    Button {
                        yaw = 0; pitch = 0
                    } label: {
                        Label("Centre", systemImage: "scope")
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Parallax Intensity")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(intensity) },
                                          set: { intensity = CGFloat($0) }),
                           in: 0.2...1.0)
                }

                if !useMotion {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Manual Tilt")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack {
                            Image(systemName: "arrow.left")
                            Slider(value: Binding(get: { Double(yaw) },
                                                  set: { yaw = CGFloat($0) }),
                                   in: -1.0...1.0)
                            Image(systemName: "arrow.right")
                        }
                        HStack {
                            Image(systemName: "arrow.down")
                            Slider(value: Binding(get: { Double(pitch) },
                                                  set: { pitch = CGFloat($0) }),
                                   in: -1.0...1.0)
                            Image(systemName: "arrow.up")
                        }
                    }
                }

                HStack {
                    Button {
                        Task { await exportVideo() }
                    } label: {
                        Label("Export Video", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(preparing)

                    if preparing {
                        ProgressView().padding(.leading, 8)
                    }
                    Spacer()
                }
            }
        }
    }

    private func loadImage(item: PhotosPickerItem?) async {
        guard let item else { return }
        preparing = true
        defer { preparing = false }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                self.originalImage = uiImage
                let engine = ParallaxEngine(image: uiImage)
                try await engine.prepare()
                self.engine = engine
                self.yaw = 0
                self.pitch = 0
            }
        } catch {
            print("Image load/prepare error:", error)
        }
    }

    private func exportVideo() async {
        guard let engine else { return }
        preparing = true
        defer { preparing = false }
        do {
            let url = try await VideoExporter.exportParallaxVideo(
                engine: engine,
                seconds: 4.0,
                fps: 30,
                baseIntensity: intensity
            )
            self.shareSheet = ShareSheet(items: [url])
        } catch {
            print("Export failed:", error)
        }
    }
}

private struct ParallaxPreview: View {
    let engine: ParallaxEngine
    let yaw: CGFloat
    let pitch: CGFloat
    let intensity: CGFloat

    var body: some View {
        if let image = engine.renderUIImage(
            yaw: yaw,
            pitch: pitch,
            intensity: intensity
        ) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}
