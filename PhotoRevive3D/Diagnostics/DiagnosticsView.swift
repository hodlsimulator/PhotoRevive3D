//
//  DiagnosticsView.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import SwiftUI

struct DiagnosticsView: View {
    @State private var logTail: String = ""
    @State private var summary: String = ""
    @State private var shareItems: [Any] = []
    @State private var presentShare = false

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
                        Task {
                            let urls = await Diagnostics.collectShareURLs()
                            await MainActor.run {
                                shareItems = urls
                                presentShare = true
                            }
                        }
                    } label: {
                        Label("Share All", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task {
                            let text = await Diagnostics.tail()
                            await MainActor.run { logTail = text }
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                Spacer(minLength: 8)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            let text = await Diagnostics.tail()
            let s = await MainActor.run { Diagnostics.deviceSummary() }
            await MainActor.run {
                logTail = text
                summary = s
            }
        }
        .sheet(isPresented: $presentShare) {
            ShareSheet(items: shareItems)
        }
    }
}
