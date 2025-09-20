//
//  PhotoRevive3DApp.swift
//  PhotoRevive3D
//
//  Wires diagnostics bootstrap + clean-exit marker.
//  Presents your existing root view.
//

import SwiftUI

@main
struct PhotoRevive3DApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        Diagnostics.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background { Diagnostics.markCleanExit() }
        }
    }
}

