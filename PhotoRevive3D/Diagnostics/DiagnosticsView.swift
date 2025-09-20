//
//  DiagnosticsView.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//
//  Simple, actor-safe diagnostics UI that works with the current Diagnostics API.
//  Shows device info, last-launch crash flag, optional crash summary/JSON,
//  a live tail of the log, and buttons to Refresh / Clear / Share logs.
//

import SwiftUI

@MainActor
struct DiagnosticsView: View {
    @State private var logTail: String = ""
    @State private var showCrashJSON: Bool = false
    @State private var shareSheet: ShareSheet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Diagnostics.deviceSummary)
                        Text("Now: \(Diagnostics.timestamp)")
                        Text("Diagnostics dir: \(Diagnostics.diagnosticsDir.path)")
                            .font(.footnote).foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Circle()
                                .fill(Diagnostics.didCrashLastLaunch ? .red : .green)
                                .frame(width: 8, height: 8)
                            Text("Last launch crashed: \(Diagnostics.didCrashLastLaunch ? "YES" : "NO")")
                        }

                        if let summary = Diagnostics.lastCrashSummary {
                            Text("Last crash: \(summary)")
                        }

                        if Diagnostics.lastCrashJSON != nil {
                            Button {
                                showCrashJSON.toggle()
                            } label: {
                                Label(showCrashJSON ? "Hide crash JSON" : "Show crash JSON", systemImage: "doc.text")
                            }
                            .buttonStyle(.bordered)

                            if showCrashJSON, let json = Diagnostics.lastCrashJSON {
                                ScrollView {
                                    Text(json)
                                        .font(.system(.footnote, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(minHeight: 120)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Log tail")
                            .font(.subheadline.weight(.semibold))
                        TextEditor(text: $logTail)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 280)
                            .scrollContentBackground(.hidden)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .padding()
        }
        .sheet(item: $shareSheet) { sheet in sheet }
        .onAppear { refreshTail() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Diagnostics")
                .font(.title2.weight(.bold))
            Spacer()
            Button {
                refreshTail()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

            Button {
                Task {
                    await Diagnostics.clearAll()
                    refreshTail()
                }
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.bordered)

            Button {
                Task {
                    let urls = await Diagnostics.collectShareURLs()
                    shareSheet = ShareSheet(items: urls)
                }
            } label: {
                Label("Share Logs", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func refreshTail() {
        // Synchronous helper; no await.
        logTail = Diagnostics.tail(maxBytes: 128_000)
    }
}
