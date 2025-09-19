//
//  DiagnosticsView.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @State private var logTail: String = ""
    @State private var deviceSummary: String = ""
    @State private var crashSummary: String = ""
    @State private var hasCrashJSON: Bool = false

    @State private var confirmClear = false

    @State private var copied = false
    @State private var copiedCrash = false
    @State private var copiedCrashSummary = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Diagnostics")
                        .font(.title2.weight(.bold))
                } icon: {
                    Image(systemName: "wrench.and.screwdriver.fill")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(deviceSummary.isEmpty ? "…" : deviceSummary)
                            .font(.subheadline)

                        Text("Last run crashed: \(Diagnostics.didCrashLastLaunch ? "YES" : "NO")")
                            .font(.subheadline)

                        Divider().padding(.vertical, 4)

                        HStack {
                            Text("Latest crash summary")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if hasCrashJSON {
                                Text("available")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("none")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Text(summaryText())
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox {
                    Text("Recent Log (last 64KB)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(logTail.isEmpty ? "No log yet." : logTail)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .frame(maxHeight: 320)
                }

                HStack {
                    Button {
                        Task { await copyAll() }
                    } label: {
                        Label(copied ? "Copied" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task { await refreshAll() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                GroupBox {
                    Text("Crash Tools")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            if !crashSummary.isEmpty {
                                UIPasteboard.general.string = crashSummary
                                withAnimation { copiedCrashSummary = true }
                            }
                        } label: {
                            Label(copiedCrashSummary ? "Summary Copied" : "Copy Crash Summary",
                                  systemImage: copiedCrashSummary ? "checkmark" : "text.document")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!hasCrashJSON || crashSummary.isEmpty)

                        Button {
                            if let json = Diagnostics.lastCrashJSON() {
                                UIPasteboard.general.string = json
                                withAnimation { copiedCrash = true }
                            }
                        } label: {
                            Label(copiedCrash ? "JSON Copied" : "Copy Crash JSON",
                                  systemImage: copiedCrash ? "checkmark" : "curlybraces")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!hasCrashJSON)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await refreshAll() }
        .alert("Clear diagnostics?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) {
                Task {
                    // Purge rolling logs, backup, ALL MetricKit JSON (MXMetric/MXDiag), and the crash marker.
                    await Diagnostics.clearAll()
                    // Also reset in-memory UI state so JSON + summary appear cleared immediately.
                    await MainActor.run {
                        withAnimation {
                            logTail = ""
                            crashSummary = ""
                            hasCrashJSON = false
                            copied = false
                            copiedCrash = false
                            copiedCrashSummary = false
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes the rolling logs, backups, MetricKit JSON payloads, and the crash marker. It also clears the displayed crash summary.")
        }
    }

    // MARK: - Helpers

    private func summaryText() -> String {
        if hasCrashJSON {
            return crashSummary.isEmpty ? "No summary available in the latest payload." : crashSummary
        } else {
            return "No crash payload found."
        }
    }

    private func refreshAll() async {
        let text = await Diagnostics.tail()
        let dev = await MainActor.run { Diagnostics.deviceSummary() }
        let sum = Diagnostics.lastCrashSummary() ?? ""
        let has = Diagnostics.lastCrashJSON() != nil

        await MainActor.run {
            withAnimation {
                copied = false
                copiedCrash = false
                copiedCrashSummary = false
            }
            logTail = text
            deviceSummary = dev
            crashSummary = sum
            hasCrashJSON = has
        }
    }

    private func copyAll() async {
        let text = await Diagnostics.tail()
        let ts = Diagnostics.timestamp()
        let dev = await MainActor.run { Diagnostics.deviceSummary() }
        var report = """
        ==== PhotoRevive3D Diagnostics ====
        Time: \(ts)
        \(dev)
        Last run crashed: \(Diagnostics.didCrashLastLaunch ? "YES" : "NO")
        ===================================

        --- Recent Log (last 64KB) ---
        """
        report += "\n" + text

        await MainActor.run {
            UIPasteboard.general.string = report
            withAnimation { copied = true }
        }
    }
}
