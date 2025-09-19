//
//  RootView.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import SwiftUI

struct RootView: View {
    @State private var showDiagnostics = false
    @State private var autoShare = false
    @State private var shareItems: [Any] = []

    var body: some View {
        ContentView()
            .task {
                // Auto-offer diagnostics if the previous run crashed.
                if Diagnostics.didCrashLastLaunch {
                    let urls = await Diagnostics.collectShareURLs()
                    await MainActor.run {
                        shareItems = urls
                        autoShare = true
                    }
                }
            }
            // Hidden five-tap on title: we can't attach here, so add a global menu button:
            .toolbar(.visible, for: .automatic)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showDiagnostics = true
                        } label: {
                            Label("Diagnostics", systemImage: "wrench.and.screwdriver")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView()
            }
            .sheet(isPresented: $autoShare) {
                ShareSheet(items: shareItems)
            }
    }
}
