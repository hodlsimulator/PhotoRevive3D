# PhotoRevive 3D

_Bring your pictures to life — entirely on-device._

PhotoRevive 3D is an **iOS 26-only** SwiftUI app that turns any still image into a tasteful 3D parallax animation with exportable video. Everything runs locally using Apple frameworks; **no servers, no logins, no third-party SDKs**.

> **Status:** Prototype (0.1.0). Core pieces exist: depth synthesis, parallax preview, optional gyro tilt, MP4 export.  
> **Updated:** 19 September 2025

---

## Requirements

- **iOS:** 26.0+
- **Xcode:** 26 (with the iOS 26 SDK)
- **Swift:** 6.x
- **Frameworks:** SwiftUI, PhotosUI, Vision, Core Image, Core Motion, AVFoundation, UniformTypeIdentifiers

This repository is a plain `.xcodeproj` with a shared scheme. Open and run — no package setup.

---

## Quick Start

1. Open `PhotoRevive3D.xcodeproj` in Xcode 26.  
2. Select the `PhotoRevive3D` scheme and an iOS 26 device (recommended) or simulator.  
3. Build & Run (⌘R).  
4. Tap **Pick Photo** → choose an image.  
5. Adjust:
   - Parallax Intensity slider  
   - Yaw / Pitch sliders (or enable **Gyro** on a real device)  
6. Tap **Export Video** to render an MP4, then share via the system share sheet.

Tip: Gyro tilt preview needs a real device (CoreMotion isn’t available in the simulator). In the simulator, use the sliders.

---

## Project Structure

    PhotoRevive3D/
    ├─ App/
    │  └─ PhotoRevive3DApp.swift          — App entry point (SwiftUI)
    ├─ UI/
    │  ├─ ContentView.swift                — Picker, controls, live preview
    │  └─ Components/
    │     └─ Glass.swift                   — “Liquid glass” styling modifier
    ├─ Engine/
    │  ├─ DepthEstimator.swift             — Depth/segmentation + fallback mask
    │  ├─ MotionTiltProvider.swift         — CoreMotion → normalised yaw/pitch
    │  ├─ ParallaxEngine.swift             — Core Image parallax compositor
    │  └─ VideoExporter.swift              — AVAssetWriter MP4 export
    ├─ Support/
    │  └─ ShareSheet.swift                 — UIActivityViewController wrapper
    ├─ Assets.xcassets/                    — App icon, colours
    └─ PhotoRevive3D.xcodeproj/            — Project, scheme, workspace data

No dependencies outside Apple’s SDKs.

---

## How It Works (High-Level)

**1) Depth synthesis**  
- If a person is detected, a Vision person-segmentation mask (softened) weights “near” regions.  
- Otherwise a smooth radial depth fallback (centre-weighted) avoids hard edges.

**2) Layering & edge soften**  
- Foreground and background layers are derived from the mask.  
- Background is slightly up-scaled to reduce edge reveal during motion.

**3) Parallax rendering**  
- For each frame, foreground/background shift in opposite directions from yaw/pitch (gyro or sliders) and intensity, then composite via Core Image.

**4) Export**  
- A short “yoyo” motion renders to MP4 (H.264) using AVAssetWriter.  
- The file URL is presented via the system share sheet.

All processing is on-device.

---

## Controls (in `ContentView.swift`)

- **Pick Photo** — system Photos picker (no full-library permission).  
- **Parallax Intensity** — overall depth motion scale.  
- **Yaw / Pitch** — manual offsets (useful in Simulator).  
- **Gyro** — toggles motion from `MotionTiltProvider`.  
- **Export Video** — calls `VideoExporter` to render MP4 and share.

---

## Build & Signing

- **Shared scheme:** `PhotoRevive3D`  
- Set your **Team** in “Signing & Capabilities” if you’re forking; Xcode will adjust provisioning.  
- **Deployment target:** iOS 26.

---

## Privacy

- **No network calls** in the prototype.  
- Uses **PhotosPicker** (read-only from explicit user selection).  
- Exports to a **temporary file** and invokes the system share sheet.

---

## Known Quirks

- Edge gaps can appear with very high intensity; mitigated by background up-scale and mask softening.  
- Gyro requires a device; expect no motion in the Simulator.  
- Export length/bit-rate are fixed in the prototype; tweak in `VideoExporter`.

---

# Roadmap — What We’ll Build & How We’ll Build It

The plan is incremental, testable, and biased toward shippable value. Each milestone lists **scope**, **acceptance criteria**, and **files likely to change**. Versioning uses **semver**.

Symbols: ✅ complete • ⏳ in progress • 🗂 planned

---

## 0.1.0 — Prototype ✅

**Scope**  
Depth + parallax preview, manual/gyro tilt, MP4 export scaffold.

**Acceptance**  
Runs on device; exports a short MP4; no crashes in normal flow.

**Files**  
`DepthEstimator.swift`, `ParallaxEngine.swift`, `MotionTiltProvider.swift`, `VideoExporter.swift`, `ContentView.swift`.

---

## 0.2.0 — MVP Polish (Foundations) 🗂

**Scope**  
- Export controls: duration (2–8 s), FPS (24/30/60), intensity curve (ease-in-out).  
- Progress UI with **cancel**; friendly error messages.  
- Performance: reuse a single `CIContext`, add a CVPixelBuffer pool, avoid per-frame allocations.  
- Orientation & layout: safe areas, landscape support, larger iPad preview.  
- Onboarding sheet (1–2 cards) explaining controls.  
- Localisation scaffolding (String Catalog; English seeded).  
- Unit tests for depth blending and mask softening (logic-level).

**Acceptance**  
- Users can pick 24/30/60 FPS and 2–8 s; cancel export mid-way; memory stable (≤ ~150 MB peak on iPhone 14/15 class devices).

**Files likely to change**  
`VideoExporter.swift` (duration/FPS/curve, buffer pool), `ContentView.swift` (UI for options, progress & cancel), `DepthEstimator.swift` (testability), new `ExportOptions.swift`, `Strings.xcstrings`.

---

## 0.3.0 — Export Formats & Presets 🗂

**Scope**  
- Aspect presets: Square (1:1), Portrait (4:5), Reels (9:16), Landscape (16:9) with safe-crop guides.  
- HEVC (H.265) option where available.  
- GIF export (fallback for messaging; cap 10 s / 15 FPS).  
- Save to Photos (user-initiated add).

**Acceptance**  
- Export panel selects aspect/FPS/codec; outputs correct pixel sizes; GIFs ≤ 15 MB at typical lengths.

**Files**  
`VideoExporter.swift` (HEVC path, resampling), `ContentView.swift` (preset picker, crop overlay), new `RenderSize.swift`, `GIFExporter.swift`.

---

## 0.4.0 — Live Photo (Investigate → Ship) 🗂

**Scope**  
- Generate a paired still + video with a shared asset identifier and write as a Live Photo (if feasible with public APIs on iOS 26).  
- If unsupported on some devices, present a clear fallback (“Save Video for Live Photo”) with a Shortcuts recipe.

**Acceptance**  
- On supported devices, “Save as Live Photo” produces a Live Photo that plays on the Lock Screen and in Photos; otherwise fallback path is shown.

**Files**  
New `LivePhotoWriter.swift`; minor changes in `VideoExporter.swift`, `ContentView.swift`.

**Risks & mitigations**  
API fragility → ship behind a beta toggle; broaden on confidence.

---

## 0.5.0 — Depth & Edges 1.0 🗂

**Scope**  
- Better matting when no person is present: combine saliency with radial fallback; optional threshold UI.  
- Edge repair to reduce gaps at high intensity: background inpainting-lite (clamped blur + gentle warp).  
- Optional depth-weighted blur for a subtle lens effect.

**Acceptance**  
- At max intensity, common edges don’t “tear”; artefacts reduced vs 0.1.0.

**Files**  
`DepthEstimator.swift`, `ParallaxEngine.swift` (mask improvements, background fill helpers).

---

## 0.6.0 — Motion Extras 🗂

**Scope**  
- Motion paths: triangle, sine, ellipse; auto pan & yoyo presets.  
- Record gyro path (2–4 s) and loop it.  
- Procedural background motion for sky/water/foliage (noise-based displacement with category detection).  
- Face micro-animations (blink/smile) when a face is detected — tasteful and very subtle.

**Acceptance**  
- Non-linear motion available; “Record” produces a smooth loop; category-based background motion works without uncanny artefacts.

**Files**  
`ParallaxEngine.swift` (parametrised motion), new `MotionPath.swift`, optional `BackgroundMotion.swift`, small UI in `ContentView.swift`.

---

## 0.7.0 — UX Polish, Accessibility, Tutorials 🗂

**Scope**  
- Haptics on key interactions; Reset/Centre refinements.  
- Accessibility: Dynamic Type, VoiceOver labels, colour-contrast safe UI.  
- Built-in tutorial (short, skippable) and a compact Tips page.

**Acceptance**  
- Passes Accessibility Inspector basics; tutorial completion stored; no inaccessible controls.

**Files**  
`ContentView.swift`, new `TutorialView.swift`, localisation strings.

---

## 0.8.0 — Performance & Battery 🗂

**Scope**  
- Optional Metal kernels for the hot path.  
- Preview frame budget: ≤ 16 ms @ 1080p on A16/A17 class devices.  
- Energy: throttle CoreMotion when idle; coalesce timers.

**Acceptance**  
- Preview smooth at target; export times improved ≥ 20% on test devices.

**Files**  
`ParallaxEngine.swift` (conditional Metal), `MotionTiltProvider.swift` (sampling), new `MetalKernels.metal` (if adopted).

---

## 0.9.0 — Monetisation & Settings 🗂

**Scope**  
- Freemium: free tier with watermark/limits; subscription removes watermark, unlocks 4K and extras.  
- Paywall (honest, lightweight) with Restore Purchases.  
- Settings pane for defaults (aspect, duration, intensity, watermark toggle).  
- Simple in-app privacy page.

**Acceptance**  
- StoreKit entitlements enforced; exports reflect plan; settings persist via `@AppStorage`.

**Files**  
New `Store.swift` (StoreKit 2), `SettingsView.swift`, watermark overlay in `ParallaxEngine`/`VideoExporter`.

---

## 1.0.0 — Launch 🎉

**Scope**  
- Final QA, App Store assets (screenshots/videos), App Privacy answers.  
- Localisation: at least English + 1 additional language.  
- Optional press kit & simple landing page.

**Acceptance**  
- App approved; stable crash-free session rate (based on MetricKit diagnostics post-launch).

---

## Stretch Goals (Post-1.0)

- Shortcuts actions (“Animate Latest Photo”, “Export with Preset”).  
- Home Screen widget showing a favourite animated photo (video loop).  
- Mac Catalyst build (preview + export).

---

## Delivery Plan — How We’ll Develop It

**Branching & releases**  
- `main`: always releasable; tags for releases (`vX.Y.Z`).  
- Feature branches: `feat/live-photo`, `feat/export-presets`, etc.; squash-merge with conventional commit messages.

**Definition of Done**  
- Compiles with zero warnings.  
- UI tested on at least one small (iPhone 13 mini/SE), one medium (iPhone 14/15), and one large (iPad) device/simulator where applicable.  
- Memory stable under export; no obvious artefacts at default intensity.  
- Localised strings present (English) and accessibility labels set for new controls.  
- Changelog updated.

**Performance budgets**  
- Preview frame: ≤ 16 ms target on A16/A17 class.  
- Export peak memory: ≤ 200 MB on iPhone 14.

**Testing**  
- Logic unit tests for mask/curve maths (no heavy image fixtures).  
- Manual device tests for Motion, Export, Share.  
- Screenshot notes for before/after on visual changes.

**Issue labels**  
- `type:bug`, `type:feature`, `type:perf`, `type:ui`, `area:engine`, `area:export`, `area:ui`, `good-first-task`.

**Risk management**  
- Ship risky features behind flags (`Features.swift`) until stable.  
- Prefer progressive enhancement (e.g., HEVC only when hardware/OS supports).

---

## Engineering Playbook

- **Style:** Swift 6, Xcode default formatting.  
- **Concurrency:** Swift Concurrency; keep CI/AV work off the main thread; UI on `@MainActor`.  
- **Errors:** Throw and handle; show short, human errors to users; log technical details with `os_log` (privacy-safe).  
- **Data:** Temporary files only; clean up on success/failure.  
- **Telemetry:** None by default. If ever added, make it opt-in and documented.  
- **Security/Privacy:** No third-party SDKs; Photos access via the system picker only.

---

## Release Checklist (for each tagged build)

- Bump version & build number; update `Changelog`.  
- Smoke test: pick → preview → export (H.264 + HEVC if enabled) → share.  
- Test on device with low storage edge case.  
- App Privacy answers reflect current behaviour.  
- Screenshots and preview video updated if UI changed.

---

## Keeping This README Inside Xcode

1) Place `README.md` at the repository root.  
2) In Xcode’s Project Navigator, right-click the top project group → “Add Files to ‘PhotoRevive3D’…”.  
3) Select `README.md`, untick “Copy items if needed”, and untick Target Membership (so it isn’t bundled in the app).  
4) Commit changes as usual:

    git add -A
    git commit -m "Update README + roadmap"

Alternatively, you can put `README.md` inside the `PhotoRevive3D/` folder; Xcode 26’s file-system-synced groups will still show it.

---

## Changelog (manual)

- 0.1.0 — Initial prototype: depth + parallax preview, gyro tilt, MP4 export scaffold.  
- 0.2.0 — Planned: export options, progress/cancel, perf pass, onboarding.  
- 0.3.0–1.0.0 — See Roadmap above.

---

## Licence

Copyright © 2025 Conor Nolan.  
All rights reserved.

If you wish to use portions of this code, please open an issue to discuss licensing.
