//
//  ContentView.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import SwiftUI
import PhotosUI
import CoreMotion

struct ContentView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var engine: ParallaxEngine?

    // Live preview controls
    @State private var yaw: CGFloat = 0.0
    @State private var pitch: CGFloat = 0.0
    @State private var intensity: CGFloat = 0.6
    @State private var useMotion = false

    // Export options
    @State private var exportSeconds: Double = 4.0     // 2…8
    @State private var exportFPS: Int = 30             // 24/30/60
    @State private var exportCurve: ExportOptions.MotionCurve = .easeInOut

    // State
    @State private var preparing = false
    @State private var exporting = false
    @State private var exportProgress: Double = 0.0
    @State private var exportTask: Task<Void, Never>?

    @State private var shareSheet: ShareSheet?
    @StateObject private var motion = MotionTiltProvider()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerBar

                Group {
                    if let engine {
                        ParallaxPreview(
                            engine: engine,
                            yaw: useMotion ? CGFloat(motion.yaw) : yaw,
                            pitch: useMotion ? CGFloat(motion.pitch) : pitch,
                            intensity: intensity
                        )
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

                exportBar
                    .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
        .sheet(item: $shareSheet) { sheet in sheet }
        .onChange(of: pickerItem) { _, newItem in
            Task { await loadImage(item: newItem) }
        }
        .onChange(of: useMotion) { _, enabled in
            if enabled { motion.start() } else { motion.stop() }
        }
    }

    // MARK: - UI Pieces

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
                    Toggle(isOn: $useMotion) {
                        Label("Gyro", systemImage: "gyroscope")
                    }
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
                    Slider(value: Binding(
                        get: { Double(intensity) },
                        set: { intensity = CGFloat($0) }
                    ), in: 0.2...1.0)
                }

                if !useMotion {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Manual Tilt")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack {
                            Image(systemName: "arrow.left")
                            Slider(value: Binding(
                                get: { Double(yaw) },
                                set: { yaw = CGFloat($0) }
                            ), in: -1.0...1.0)
                            Image(systemName: "arrow.right")
                        }
                        HStack {
                            Image(systemName: "arrow.down")
                            Slider(value: Binding(
                                get: { Double(pitch) },
                                set: { pitch = CGFloat($0) }
                            ), in: -1.0...1.0)
                            Image(systemName: "arrow.up")
                        }
                    }
                }
            }
        }
    }

    private var exportBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if engine != nil {
                // Export options
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Export Options")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }

                        HStack(spacing: 16) {
                            VStack(alignment: .leading) {
                                Text("Duration \(String(format: "%.1f", exportSeconds))s")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(value: $exportSeconds, in: 2.0...8.0, step: 0.5)
                            }

                            VStack(alignment: .leading) {
                                Text("FPS \(exportFPS)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $exportFPS) {
                                    Text("24").tag(24)
                                    Text("30").tag(30)
                                    Text("60").tag(60)
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 200)
                            }
                        }

                        VStack(alignment: .leading) {
                            Text("Motion Curve")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $exportCurve) {
                                Text("Linear").tag(ExportOptions.MotionCurve.linear)
                                Text("Smooth").tag(ExportOptions.MotionCurve.easeInOut)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 220)
                        }
                    }
                }

                // Export buttons + progress
                HStack(spacing: 12) {
                    Button {
                        startExport()
                    } label: {
                        Label("Export Video", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(preparing || exporting)

                    if exporting {
                        ProgressView(value: exportProgress)
                            .frame(width: 120)
                        Button(role: .destructive) {
                            exportTask?.cancel()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()
                }
            }

            if preparing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func loadImage(item: PhotosPickerItem?) async {
        guard let item else { return }

        await MainActor.run { preparing = true }

        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                let engine = ParallaxEngine(image: uiImage)
                try await engine.prepare()
                await MainActor.run {
                    self.engine = engine
                    self.yaw = 0
                    self.pitch = 0
                }
            }
        } catch {
            print("Image load/prepare error:", error)
        }

        await MainActor.run { preparing = false }
    }

    private func startExport() {
        guard let engine else { return }
        exporting = true
        exportProgress = 0
        shareSheet = nil

        let options = ExportOptions(
            seconds: exportSeconds,
            fps: exportFPS,
            baseIntensity: intensity,
            curve: exportCurve
        )

        exportTask = Task(priority: .userInitiated) {
            do {
                let url = try await VideoExporter.exportParallaxVideo(
                    engine: engine,
                    options: options
                ) { progress in
                    // Hop to the main actor for UI state safely.
                    Task { @MainActor in
                        exportProgress = progress
                    }
                }
                await MainActor.run {
                    exporting = false
                    shareSheet = ShareSheet(items: [url])
                }
            } catch is CancellationError {
                await MainActor.run { exporting = false }
            } catch {
                await MainActor.run { exporting = false }
                print("Export failed:", error)
            }
        }
    }
}

private struct ParallaxPreview: View {
    let engine: ParallaxEngine
    let yaw: CGFloat
    let pitch: CGFloat
    let intensity: CGFloat

    var body: some View {
        if let image = engine.renderUIImage(yaw: yaw, pitch: pitch, intensity: intensity) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}
