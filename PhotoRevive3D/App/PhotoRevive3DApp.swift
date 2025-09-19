//
//  PhotoRevive3DApp.swift
//  PhotoRevive3D
//

import SwiftUI

@main
struct PhotoRevive3DApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Diagnostics.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .onChange(of: scenePhase) { _, phase in
            // Remove the crash marker on a clean background transition.
            if phase == .background {
                Diagnostics.markCleanExit()
                Diagnostics.log(.info, "Scene moved to background; marking clean exit")
            }
        }
    }
}
