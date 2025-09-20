//
//  RootView.swift
//  PhotoRevive3D
//
//  Created by . . on 19/09/2025.
//
//  Minimal host that can present Diagnostics without a bottom nav bar.
//

import SwiftUI

struct RootView: View {
    @State private var showDiagnostics = false

    var body: some View {
        ContentView()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDiagnostics = true
                    } label: { Image(systemName: "wrench.and.screwdriver") }
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView()
            }
    }
}
