//
//  DiagnosticsView.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//
//  Actor-safe diagnostics UI (sheet-friendly, no nav bar):
//  • Rich hardware/system summary (screen, RAM, storage, locale, TZ, power, thermal).
//  • Crash summary + JSON viewer (MetricKit payloads saved on demand).
//  • Live tail of the rolling app log.
//  • Bottom action bar (Refresh / Clear / Share / Enable MetricKit).
//

import SwiftUI
import UIKit

@MainActor
struct DiagnosticsView: View {
    @Environment(\.displayScale) private var envDisplayScale

    @State private var logTail: String = ""
    @State private var jsonFiles: [URL] = []
    @State private var selectedJSONText: String?
    @State private var showJSONSheet = false
    @State private var shareSheet: ShareSheet?
    @State private var metricKitEnabled = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // SUMMARY
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Summary").font(.subheadline.weight(.semibold))
                            summaryText
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }

                    // CRASH / JSON
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Crash & Diagnostic JSON").font(.subheadline.weight(.semibold))

                            HStack(spacing: 8) {
                                Circle().fill(Diagnostics.didCrashLastLaunch ? .red : .green)
                                    .frame(width: 8, height: 8)
                                Text("Last launch crashed: \(Diagnostics.didCrashLastLaunch ? "YES" : "NO")")
                            }

                            if let summary = Diagnostics.lastCrashSummary {
                                Text("Last crash: \(summary)").font(.footnote)
                            } else {
                                Text("No parsed crash summary found.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }

                            if !jsonFiles.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Diagnostic JSON files (\(jsonFiles.count)):")
                                        .font(.footnote.weight(.semibold))
                                    ForEach(jsonFiles.prefix(10), id: \.self) { url in
                                        HStack {
                                            Text(url.lastPathComponent)
                                                .font(.footnote)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer()
                                            Button {
                                                if let txt = try? String(contentsOf: url, encoding: .utf8) {
                                                    selectedJSONText = txt
                                                    showJSONSheet = true
                                                }
                                            } label: {
                                                Label("View", systemImage: "doc.text.magnifyingglass")
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                    if jsonFiles.count > 10 {
                                        Text("…and \(jsonFiles.count - 10) more").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                Text("No MetricKit JSON payloads yet. Enable MetricKit below, then reproduce the issue; payloads appear here.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // LOG TAIL
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Log tail").font(.subheadline.weight(.semibold))
                            TextEditor(text: $logTail)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(minHeight: 280)
                                .scrollContentBackground(.hidden)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }

                    // Spacer to avoid being covered by the bottom bar
                    Color.clear.frame(height: 80)
                }
                .padding()
            }

            // Bottom action bar (sheet-friendly; no nav bar)
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        refreshAll()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await Diagnostics.clearAll(); refreshAll() }
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task {
                            let urls = await Diagnostics.collectShareURLs()
                            shareSheet = ShareSheet(items: urls)
                        }
                    } label: {
                        Label("Share Logs", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal).padding(.top, 8)

                // Optional: enable MetricKit on-demand (safe; not at launch)
                HStack {
                    Button {
                        enableMetricKit()
                    } label: {
                        Label(metricKitEnabled ? "MetricKit Enabled" : "Enable MetricKit", systemImage: "bolt.badge.a")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(metricKitEnabled)
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
                .background(.ultraThinMaterial)
            }
        }
        .sheet(item: $shareSheet) { sheet in sheet }
        .sheet(isPresented: $showJSONSheet) {
            // Simple JSON viewer sheet (monospaced)
            ScrollView {
                Text(selectedJSONText ?? "(no data)")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear { refreshAll() }
    }

    private func refreshAll() {
        logTail = Diagnostics.tail(maxBytes: 128_000)           // safe (no underflow)
        jsonFiles = loadJSONFiles()
    }

    private func enableMetricKit() {
        // Start subscriber on demand; safe (we intentionally skip doing this at launch).
        #if canImport(MetricKit)
        if #available(iOS 14.0, *) {
            MetricsSubscriber.shared.start()
            metricKitEnabled = true
            // Refresh soon after enabling; payloads arrive asynchronously.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { refreshAll() }
        }
        #endif
    }

    // Build a richer hardware/system summary (monospaced) without UIScreen.main
    private var summaryText: Text {
        let screen = activeScreen()
        let native = screen?.nativeBounds ?? .zero
        let scale = screen?.scale ?? envDisplayScale
        let points = screen?.coordinateSpace.bounds.size ?? .zero

        let d = UIDevice.current
        let locale = Locale.current.identifier
        let tz = TimeZone.current.identifier
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON" : "OFF"
        let thermal: String = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "nominal"
            case .fair:    return "fair"
            case .serious: return "serious"
            case .critical:return "critical"
            @unknown default: return "unknown"
            }
        }()

        let ram = ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory),
                                            countStyle: .binary)
        let (diskFree, diskTotal) = storageTuple()
        let uptime = String(format: "%.0fs", ProcessInfo.processInfo.systemUptime)

        let screenLine: String = {
            if native == .zero || points == .zero {
                return String(format: "Screen: (unavailable) @%.2fx", scale)
            } else {
                return String(format: "Screen: %.0fx%.0fpt (native: %.0fx%.0f) @%.2fx",
                              points.width, points.height, native.width, native.height, scale)
            }
        }()

        let lines: [String] = [
            "Device: \(d.model)",
            "OS: \(d.systemName) \(d.systemVersion)",
            screenLine,
            "Locale: \(locale)   Timezone: \(tz)",
            "Low Power: \(lowPower)   Thermal: \(thermal)",
            "RAM: \(ram)",
            "Storage: \(diskFree) free / \(diskTotal) total",
            "Uptime: \(uptime)"
        ]

        return Text(lines.joined(separator: "\n"))
    }

    // Get the UIScreen for the current foreground scene (no UIScreen.main)
    private func activeScreen() -> UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
            return active.screen
        }
        return scenes.first?.screen
    }

    // Synchronous list of JSON files (latest first)
    private func loadJSONFiles() -> [URL] {
        let dir = Diagnostics.diagnosticsDir
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir,
                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let jsons = items.filter { $0.pathExtension.lowercased() == "json" }
        return jsons.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
    }

    // Human-friendly disk space summary
    private func storageTuple() -> (free: String, total: String) {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
            let fmt = ByteCountFormatter()
            fmt.allowedUnits = [.useGB, .useMB]
            fmt.countStyle = .decimal
            return (fmt.string(fromByteCount: free), fmt.string(fromByteCount: total))
        } catch {
            return ("n/a", "n/a")
        }
    }
}
