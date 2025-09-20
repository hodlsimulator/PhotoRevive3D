//
//  DiagnosticsView.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//
//  iOS 26 "glass" redesign, no bottom nav. Top bar with Close / Share / Refresh / Clear.
//  Includes hardware summary, crash summary, live log tail, and MetricKit controls.
//  Safe JSON viewer (no table parsing).
//

import SwiftUI
import MetricKit

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var logTail: String = ""
    @State private var jsonTail: String = ""
    @State private var crashSummary: String? = Diagnostics.lastCrashSummary
    @State private var showingShare = false
    @State private var shareItems: [Any] = []
    @State private var showingJSON = false
    @State private var latestJSON: String = Diagnostics.lastCrashJSON ?? "(no MetricKit JSON yet)"
    @State private var metricsOn: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 16) {
                    Spacer(minLength: 68) // room for top bar
                    // Summary card
                    GlassCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Diagnostics")
                                .font(.largeTitle).fontWeight(.semibold)
                            Text(Diagnostics.deviceSummary)
                                .font(.body).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Label(Diagnostics.didCrashLastLaunch ? "Previous launch crashed" : "Previous launch clean",
                                      systemImage: Diagnostics.didCrashLastLaunch ? "exclamationmark.triangle" : "checkmark.seal")
                                    .labelStyle(.titleAndIcon)
                                    .font(.subheadline)
                                if metricsOn {
                                    Label("MetricKit: ON", systemImage: "waveform.path.ecg")
                                        .font(.subheadline)
                                } else {
                                    Label("MetricKit: OFF", systemImage: "waveform.path.ecg")
                                        .foregroundStyle(.secondary)
                                        .font(.subheadline)
                                }
                            }.padding(.top, 4)
                        }
                    }

                    // Crash summary + JSON viewer
                    if let crashSummary {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Latest Diagnostic")
                                    .font(.headline)
                                Text(crashSummary)
                                    .font(.subheadline)
                                Button {
                                    latestJSON = Diagnostics.lastCrashJSON ?? "(no MetricKit JSON yet)"
                                    showingJSON = true
                                } label: {
                                    Label("View JSON", systemImage: "doc.text.magnifyingglass")
                                }
                                .buttonStyle(.bordered)
                                .padding(.top, 4)
                            }
                        }
                    }

                    // MetricKit controls
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("MetricKit")
                                .font(.headline)
                            Text("Start/stop collection on demand. Payloads save as JSON and never go through a brittle table.")
                                .font(.footnote).foregroundStyle(.secondary)
                            HStack {
                                Button {
                                    MetricsSubscriber.shared.start()
                                    metricsOn = true
                                } label: { Label("Start", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)

                                Button {
                                    MetricsSubscriber.shared.stop()
                                    metricsOn = false
                                } label: { Label("Stop", systemImage: "stop.fill") }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    // Live log tail (text)
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Log (text)")
                                .font(.headline)
                            ScrollView(.vertical) {
                                Text(logTail.isEmpty ? "(no log yet)" : logTail)
                                    .font(.system(.footnote, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(minHeight: 160, maxHeight: 240)
                        }
                    }

                    // Live JSON log (tail)
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Log (JSON)")
                                .font(.headline)
                            ScrollView(.vertical) {
                                Text(jsonTail.isEmpty ? "(no JSON log yet)" : jsonTail)
                                    .font(.system(.footnote, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(minHeight: 160, maxHeight: 240)
                        }
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }

            // Top glass bar
            GlassTopBar {
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    Task {
                        await Diagnostics.clearAll()
                        await refresh()
                    }
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        shareItems = await Diagnostics.collectShareURLs()
                        showingShare = true
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up") // shortened label
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .background(.thickMaterial.opacity(0.05))
        .onAppear {
            Task { await refresh() }
        }
        .sheet(isPresented: $showingShare) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showingJSON) {
            JSONViewer(json: latestJSON)
        }
    }

    @MainActor
    private func refresh() async {
        // Pull fresh tails from the actor (large reads off the main thread)
        logTail = await LogSink.shared.tailText(maxBytes: 64 * 1024)
        jsonTail = await LogSink.shared.tailJSON(maxBytes: 64 * 1024)
        crashSummary = Diagnostics.lastCrashSummary
    }
}

// Simple JSON viewer (avoids tables entirely)
private struct JSONViewer: View {
    let json: String
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(json.isEmpty ? "(empty JSON)" : json)
                    .font(.system(.footnote, design: .monospaced))
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("MetricKit JSON")
        }
    }
}
