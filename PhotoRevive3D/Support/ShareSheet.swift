//
//  ShareSheet.swift
//  PhotoRevive3D
//
//  Created by . . on 9/19/25.
//

import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable, Identifiable {
    let id = UUID()
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
