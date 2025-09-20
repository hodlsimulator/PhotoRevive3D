//
//  Glass.swift
//  PhotoRevive3D
//
//  Created by . . on 9/19/25.
//
//  Simple “liquid glass” card using system materials, implemented as a ViewModifier
//  to avoid actor-isolation issues with extension methods.
//

import SwiftUI

@MainActor
public struct GlassCard: ViewModifier {
    public var cornerRadius: CGFloat = 16

    public func body(content: Content) -> some View {
        content
            .padding()
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(radius: 8, y: 4)
    }
}
