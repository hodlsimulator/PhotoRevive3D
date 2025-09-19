# PhotoRevive 3D

Bring your pictures to life — entirely on-device.

PhotoRevive 3D is an iOS 26-only SwiftUI app that turns any still image into a tasteful 3D parallax animation with exportable video. Everything runs locally using Apple frameworks; no servers, logins, or third-party SDKs.

> Status: prototype. Core pieces are in place (depth synthesis, parallax preview, optional gyro tilt, MP4 export).

---

## Requirements

- iOS: 26.0+
- Xcode: 26 (with the iOS 26 SDK)
- Swift: 6.x
- Frameworks: SwiftUI, PhotosUI, Vision, Core Image, Core Motion, AVFoundation, UniformTypeIdentifiers

This repository is a plain .xcodeproj with a shared scheme. Open and run — no package setup.

---

## Quick Start

1. Open `PhotoRevive3D.xcodeproj` in Xcode 26.
2. Select the `PhotoRevive3D` scheme and an iOS 26 device (recommended) or simulator.
3. Build & Run (⌘R).
4. Tap “Pick Photo” → choose an image.
5. Adjust:
   • Parallax Intensity slider  
   • Yaw / Pitch sliders (or enable “Gyro” on a real device)
6. Tap “Export Video” to render an MP4, then share via the system share sheet.

Tip: Gyro tilt preview needs a real device (CoreMotion isn’t available in the simulator). On the simulator, use the sliders.

---

## Project Structure

    PhotoRevive3D/
    ├─ App/
    │  └─ PhotoRevive3DApp.swift         — App entry point (SwiftUI)
    ├─ UI/
    │  ├─ ContentView.swift               — Picker, controls, live preview
    │  └─ Components/
    │     └─ Glass.swift                  — “Liquid glass” styling modifier
    ├─ Engine/
    │  ├─ DepthEstimator.swift            — Depth/segmentation + fallback mask
    │  ├─ MotionTiltProvider.swift        — CoreMotion → normalised yaw/pitch
    │  ├─ ParallaxEngine.swift            — Core Image parallax compositor
    │  └─ VideoExporter.swift             — AVAssetWriter MP4 export
    ├─ Support/
    │  └─ ShareSheet.swift                — UIActivityViewController wrapper
    ├─ Assets.xcassets/                   — App icon, colours
    └─ PhotoRevive3D.xcodeproj/           — Project, scheme, workspace data

No dependencies outside Apple’s SDKs.

---

## How It Works (High-Level)

1) Depth Synthesis  
• If a person is detected, a Vision person-segmentation mask is used (softened) to weight “near” regions.  
• Otherwise a smooth radial depth fallback is generated (centre-weighted) to avoid hard edges.

2) Layering & Edge Soften  
• Foreground and background layers are derived from the mask.  
• Background is slightly up-scaled to reduce edge reveal during motion.

3) Parallax Rendering  
• For each frame, foreground/background are shifted in opposite directions based on yaw/pitch (from gyro or sliders) and intensity, then composited via Core Image.

4) Export  
• A short “yoyo” motion is rendered to MP4 (H.264) using AVAssetWriter.  
• The file URL is presented via the system share sheet.

All processing is on-device.

---

## Controls (in `ContentView.swift`)

- Pick Photo — system Photos picker (no full-library permission).
- Parallax Intensity — overall depth motion scale.
- Yaw / Pitch — manual offsets (useful in Simulator).
- Gyro — toggles motion from `MotionTiltProvider`.
- Export Video — calls `VideoExporter` to render MP4 and share.

---

## Keeping This README Inside Xcode

To keep commits tidy, edit the README directly in Xcode:

1) Place `README.md` at the repository root.  
2) In Xcode’s Project Navigator, right-click the top project group → “Add Files to ‘PhotoRevive3D’…”.  
3) Select `README.md`, untick “Copy items if needed”, and untick Target Membership (so it isn’t bundled in the app).  
4) Commit changes as usual:

    git add -A
    git commit -m "Update README"

Alternatively, you can put `README.md` inside the `PhotoRevive3D/` folder; Xcode 26’s file-system-synced groups will still show it.

---

## Build & Signing

- Shared scheme: `PhotoRevive3D`.
- Set your Team in “Signing & Capabilities” if you’re forking; Xcode will adjust provisioning.
- Deployment target: iOS 26.

---

## Privacy

- No network calls in the prototype.  
- Uses PhotosPicker (read-only from explicit user selection).  
- Exports to a temporary file and invokes the system share sheet.

---

## Known Quirks

- Edge gaps can appear with very high intensity; mitigated by background up-scale and mask softening.  
- Gyro requires a device; expect no motion in the Simulator.  
- Export length/bitrate are fixed in the prototype; tweak in `VideoExporter`.

---

## Roadmap (Short)

- Live Photo export.  
- Subtle face micro-animations (blink/smile), still fully on-device.  
- Procedural background motion (sky/water/foliage) via Vision detection.  
- Additional output presets (square/portrait/reels) and quality controls.  
- Localisation (String Catalog) + concise in-app tutorial.

---

## Development Notes

- Concurrency: Swift Concurrency (MainActor for UI).  
- Rendering: Core Image pipelines; safe to swap in Metal kernels later.  
- Testing: Prefer real devices (for CoreMotion and performance realism).

---

## Troubleshooting

- No scheme? Clean build folder (⇧⌘K), then re-open the project.  
- Build fails after moving files? Check Target Membership in the File inspector for each Swift file.  
- Export crashes on low storage? Free space; AVAssetWriter needs contiguous temporary storage.

---

## Licence

Copyright © 2025 Conor Nolan.
All rights reserved.

If you wish to use portions of this code, please open an issue to discuss licensing.

---

## Changelog (manual)

- 0.1.0 — Initial prototype: depth + parallax preview, gyro tilt, MP4 export scaffold.
