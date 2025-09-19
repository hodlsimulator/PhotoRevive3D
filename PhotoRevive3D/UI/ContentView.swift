//
//  ContentView.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import SwiftUI
import PhotosUI
import CoreMotion
import CoreImage
import UIKit

struct ContentView: View {
    @Environment(\.displayScale) private var displayScale

    @State private var pickerItem: PhotosPickerItem?
    @State private var engine: ParallaxEngine?

    // Live preview controls
    @State private var yaw: CGFloat = 0.0
    @State private var pitch: CGFloat = 0.0
    @State private var intensity: CGFloat = 0.6
    @State private var useMotion = false

    // Export options
    @State private var exportSeconds: Double = 4.0 // 2…8
    @State private var exportFPS: Int = 30         // 24/30/60
    @State private var exportCurve: ExportOptions.MotionCurve = .easeInOut

    // State
    @State private var preparing = false
    @State private var exporting = false
    @State private var exportProgress: Double = 0.0
    @State private var exportTask: Task<Void, Never>?
    @State private var shareSheet: ShareSheet?

    // Coalesced preview rendering (off-main)
    @State private var previewImage: UIImage?
    @State private var renderInFlight = false
    @State private var pendingParams: (yaw: CGFloat, pitch: CGFloat, intensity: CGFloat)?

    @StateObject private var motion = MotionTiltProvider()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerBar

                Group {
                    if let eng = engine {
                        previewCard
                            .aspectRatio(eng.outputAspect, contentMode: .fit)
                            .glassCard()
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

        // Image picker
        .onChange(of: pickerItem) { _, newItem in
            Task { await loadImage(item: newItem) }
        }

        // Gyro toggle
        .onChange(of: useMotion) { _, enabled in
            if enabled {
                Diagnostics.log(.info, "Gyro toggle: ON", category: "gyro")
                motion.start()
                schedulePreview()
            } else {
                Diagnostics.log(.info, "Gyro toggle: OFF", category: "gyro")
                motion.stop()
            }
        }

        // Live updates — coalesced
        .onChange(of: motion.yaw) { _, _ in if useMotion { schedulePreview() } }
        .onChange(of: motion.pitch) { _, _ in if useMotion { schedulePreview() } }
        .onChange(of: intensity) { _, _ in schedulePreview() }
        .onChange(of: yaw) { _, _ in if !useMotion { schedulePreview() } }
        .onChange(of: pitch) { _, _ in if !useMotion { schedulePreview() } }
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

    private var previewCard: some View {
        ZStack {
            if let image = previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        // Measure the actual displayed size (in points), convert to pixels with displayScale,
        // and update the engine’s preview LOD to match the screen.
        .overlay(
            GeometryReader { geo in
                Color.clear
                    .onAppear { updateLODFrom(size: geo.size) }
                    .onChange(of: geo.size) { _, newSize in
                        updateLODFrom(size: newSize)
                    }
            }
        )
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
                        Diagnostics.log(.debug, "Manual centre applied", category: "gyro")
                        schedulePreview()
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
                    Button { startExport() } label: {
                        Label("Export Video", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(preparing || exporting)

                    if exporting {
                        ProgressView(value: exportProgress)
                            .frame(width: 120)
                        Button(role: .destructive) { exportTask?.cancel() } label: {
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
                Diagnostics.log(.info, "Image loaded; engine prepared (size=\(engine.outputSize.width)x\(engine.outputSize.height))", category: "engine")
                schedulePreview() // first preview
            }
        } catch {
            Diagnostics.log(.error, "Image load/prepare error: \(error)", category: "engine")
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

        Diagnostics.log(.info, "Export started (duration=\(exportSeconds)s, fps=\(exportFPS))", category: "export")

        exportTask = Task(priority: .userInitiated) {
            do {
                let url = try await VideoExporter.exportParallaxVideo(
                    engine: engine,
                    options: options
                ) { progress in
                    Task { @MainActor in exportProgress = progress }
                }
                await MainActor.run {
                    exporting = false
                    shareSheet = ShareSheet(items: [url])
                }
                Diagnostics.log(.info, "Export finished → \(url.lastPathComponent)", category: "export")
            } catch is CancellationError {
                await MainActor.run { exporting = false }
                Diagnostics.log(.warn, "Export cancelled", category: "export")
            } catch {
                await MainActor.run { exporting = false }
                Diagnostics.log(.error, "Export failed: \(error)", category: "export")
            }
        }
    }

    // MARK: - Preview LOD + coalesced renderer

    /// Update engine preview LOD based on the on-screen size (in points → pixels).
    private func updateLODFrom(size: CGSize) {
        guard size.width > 0, size.height > 0, let eng = engine else { return }
        let longestPx = max(size.width, size.height) * displayScale
        let target = max(256, (longestPx / 64).rounded() * 64)
        if abs(target - eng.previewTargetLongest) > 96 {
            eng.updatePreviewLOD(targetLongestPx: target)
            schedulePreview()
        }
    }

    private func currentParams() -> (yaw: CGFloat, pitch: CGFloat, intensity: CGFloat)? {
        guard engine != nil else { return nil }
        if useMotion {
            return (CGFloat(motion.yaw), CGFloat(motion.pitch), intensity)
        } else {
            return (yaw, pitch, intensity)
        }
    }

    private func schedulePreview() {
        guard let params = currentParams() else { return }
        pendingParams = params
        guard !renderInFlight else { return }

        renderInFlight = true

        DispatchQueue.global(qos: .userInitiated).async {
            // Local CIContext used only on this background thread.
            let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
            var frames = 0

            while true {
                // Pull latest params + snapshot on main (fast), clear pending (coalesce).
                var snap: ParallaxEngine.PreviewSnapshot?
                var next: (yaw: CGFloat, pitch: CGFloat, intensity: CGFloat)?
                DispatchQueue.main.sync {
                    snap = self.engine?.makePreviewSnapshot()
                    next = self.pendingParams
                    self.pendingParams = nil
                }
                guard let snapshot = snap, let params = next else { break }

                // Compose off-main.
                let ci = ParallaxEngine.composePreview(from: snapshot,
                                                       yaw: params.yaw,
                                                       pitch: params.pitch,
                                                       intensity: params.intensity)

                // Convert CI → CG → UIImage off-main (tight autorelease scope).
                let image: UIImage? = autoreleasepool {
                    guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
                    return UIImage(cgImage: cg)
                }

                frames += 1
                if (frames % 30) == 0 { context.clearCaches() }

                DispatchQueue.main.async {
                    self.previewImage = image
                }
            }

            DispatchQueue.main.async {
                self.renderInFlight = false
            }
        }
    }
}
