//
//  ShareSheet.swift
//  PhotoRevive3D
//
//  Created by . . on 9/19/25.
//
//  UIKit share sheet wrapper (URLs, Strings, etc).
//  Conforms to Identifiable so you can use `.sheet(item:)`.
//

import SwiftUI

struct ShareSheet: UIViewControllerRepresentable, Identifiable {
    let id = UUID()
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.excludedActivityTypes = [.assignToContact, .addToReadingList, .print]
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
