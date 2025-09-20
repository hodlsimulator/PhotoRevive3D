//
//  Glass.swift
//  PhotoRevive3D
//
//  Created by . . on 9/19/25.
//
//  Lightweight “liquid glass” primitives for iOS 26 look.
//

import SwiftUI

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

struct GlassTopBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            VisualEffectBlur(material: .systemUltraThinMaterial, blendingMode: .behindWindow)
                .frame(height: 60)
                .overlay(Divider().frame(maxHeight: .infinity, alignment: .bottom))
            HStack(spacing: 10) {
                content
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

// UIKit blur that plays nice behind SwiftUI content
private struct VisualEffectBlur: UIViewRepresentable {
    let material: UIBlurEffect.Style
    let blendingMode: UIBlurEffect.Style // kept for API symmetry

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: material))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: material)
    }
}
