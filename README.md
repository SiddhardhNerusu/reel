# Reel

Native macOS demo recorder — records your screen and *automatically* turns raw footage
into a polished product demo (auto-zoom toward clicks, eased cursor, padded gradient
background). One-time purchase, offline, no account. See `BUILD_PLAN.md` for the full spec.

## Build

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonsm/XcodeGen).

```bash
brew install xcodegen        # once
xcodegen generate            # writes Reel.xcodeproj (git-ignored, disposable)
open Reel.xcodeproj
```

Command-line (compile + pure-math tests, no signing needed):

```bash
xcodegen generate
xcodebuild -project Reel.xcodeproj -scheme Reel test  CODE_SIGNING_ALLOWED=NO   # SP-10 math
xcodebuild -project Reel.xcodeproj -scheme Reel build CODE_SIGNING_ALLOWED=NO   # whole app
```

To actually **run** capture (SP-0/SP-1/M1) you must open in Xcode and sign with your
Apple Developer team, then grant Screen Recording (and Microphone) in System Settings.
TCC grants are bound to the signing identity — keep a stable Developer ID (§7).

## Targets

- **Reel** — the product.
- **ReelSpikes** — the M0 spike harness (BUILD_PLAN §10). Run this first; it exercises the
  real capture/event/compositor code so findings land in production modules.
- **ReelTests** — SP-10 pure-math regression suite (spring / clustering / clamp / transform).

## Layout (mirrors BUILD_PLAN §3)

```
Reel/
  App/         @main + coordinator
  UI/          SwiftUI views
  Capture/     ScreenCaptureKit + permissions        (§5.1)
  Events/      host clock + CGEventTap timeline       (§5.2)
  CameraPath/  spring + clustering + solve (pure)     (§5.3)  ← the moat, unit-tested
  Compositing/ the ONE pure compose fn                (§5.4)
  Export/      reader→compose→writer, GIF             (§5.5)
  Preview/     AVVideoComposition (same compose fn)   (§5.6)
  Model/       .reelproj document package             (§6)
Spikes/        SP-0…SP-6 harness
Tests/         SP-10
```

## Build order (BUILD_PLAN §11)

Scaffold → SP-10 green → SP-0…SP-6 in ReelSpikes → M1 capture → M2 events → M3 auto-zoom
(the moat) → M4 polish → M5 export suite → M6 editor → M7 dist/licensing → M8 launch.

## Dev signing (stable TCC identity)

macOS ties Screen Recording / Accessibility grants to the app's code-signing
identity, and Xcode's automatic signing churns between the two dev certs on
this Mac — invalidating the grant on every rebuild. Always build the app you
actually run with:

```
scripts/sign_dev.sh [Debug|Release]   # default Debug
```

It builds into `build/DerivedData` and force-re-signs with the pinned cert
`850BD19B…` (team KX4SBPJ7C4). Grant Screen Recording + Accessibility to that
binary once in System Settings; the grant then survives rebuilds.
