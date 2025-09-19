//
//  Glass.swift
//  PhotoRevive3D
//
//  Created by . . on 9/19/25.
//

import SwiftUI

extension View {
    /// Simple “liquid glass” style card using system materials.
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        self
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            }
            .shadow(radius: 8, y: 4)
    }
}
