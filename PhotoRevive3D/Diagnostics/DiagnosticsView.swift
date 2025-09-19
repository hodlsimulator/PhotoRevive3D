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
    @State private var summary: String = ""
    @State private var confirmClear = false
    @State private var copied = false

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
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.isEmpty ? "…" : summary)
                            .font(.subheadline)
                        Text("Last run crashed: \(Diagnostics.didCrashLastLaunch ? "YES" : "NO")")
                            .font(.subheadline)
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
                    .disabled(logTail.isEmpty && summary.isEmpty)

                    Button {
                        Task { await refresh() }
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

                if copied {
                    Text("Copied to clipboard.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Spacer(minLength: 8)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await initialLoad() }
        .alert("Clear diagnostics?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) {
                Task { await clearAndRefresh() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes the rolling logs, backup, MetricKit payloads, and the crash marker.")
        }
    }

    // MARK: - Actions

    private func initialLoad() async {
        let text = await Diagnostics.tail()
        let s = await MainActor.run { Diagnostics.deviceSummary() }
        await MainActor.run {
            logTail = text
            summary = s
        }
    }

    private func refresh() async {
        let text = await Diagnostics.tail()
        await MainActor.run {
            withAnimation { copied = false }
            logTail = text
        }
    }

    private func clearAndRefresh() async {
        await Diagnostics.clearAll()
        let text = await Diagnostics.tail()
        await MainActor.run {
            withAnimation { copied = false }
            logTail = text
        }
    }

    private func copyAll() async {
        // Build a fresh, single text blob and copy it to the clipboard.
        let text = await Diagnostics.tail()
        let ts = Diagnostics.timestamp()
        let s = await MainActor.run { Diagnostics.deviceSummary() }

        var report = """
        ==== PhotoRevive3D Diagnostics ====
        Time: \(ts)
        \(s)
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
