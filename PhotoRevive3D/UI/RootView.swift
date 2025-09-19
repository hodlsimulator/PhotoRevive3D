//
//  RootView.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//

import SwiftUI

struct RootView: View {
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            ContentView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
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
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
        }
    }
}
