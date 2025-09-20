//
//  PhotoRevive3DApp.swift
//  PhotoRevive3D
//
//  Created by . . on 9/20/25.
//

import SwiftUI
import UIKit

@main
struct PhotoRevive3DApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Diagnostics.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // View-level subscription; Scenes don’t have .onReceive
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    Diagnostics.markCleanExit()
                    Diagnostics.log(.info, "App will terminate; marking clean exit")
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Diagnostics.markLaunch()
                Diagnostics.log(.info, "Scene became active; running marker set")
            case .background:
                Diagnostics.markCleanExit()
                Diagnostics.log(.info, "Scene moved to background; marking clean exit")
            default:
                break
            }
        }
    }
}
