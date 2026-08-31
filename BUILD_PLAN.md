# DemoRecorder — End-to-End Build Plan

> **Product (codename "Reel" — name is provisional, see Open Decision #1):** a native macOS app that records your screen and *automatically* turns raw footage into a polished product demo — auto-zoom/pan toward where you click, a smooth eased cursor, a padded gradient background with rounded corners + drop shadow — then exports MP4 / GIF / MOV. One-time purchase, no subscription, no cloud, no account.
>
> **Goal (honest):** a few hundred $/month + a strong native-macOS portfolio piece. **Not** a Screen-Studio-sized outcome — see §11.

---

## 0. HOW TO USE THIS DOCUMENT (read first, implementing session)

This plan was produced from verified research (Apple docs + real competitor teardowns). It is written so you can build without inventing API details. **Operating rules:**

1. **Build the SPIKES in §10 FIRST.** Every item flagged `⚠️ SPIKE` is something we did *not* fully verify on-device (exact timestamp units, sandbox behavior, a filter's availability, etc.). Do not write production code against a spike assumption until the spike confirms it. Each spike is small (an afternoon).
2. **Exact API names live in §12 (API Appendix).** These class/method/type names were verified against Apple documentation (URLs included). Use them verbatim. If you need an API not listed there, look it up in Apple docs — **do not guess a signature from memory.**
3. **The architecture in §3 is load-bearing.** The "record raw video + a separate synchronized event timeline, then re-composite offline" model is the whole design. Do not try to bake zoom into the live capture.
4. **When in doubt, prefer the simpler verified path.** Core Image over raw Metal; AVAssetWriter over clever shortcuts. Metal is the profiling-driven escape hatch (§5.4), not the default.
5. **Confidence is marked.** `[HIGH]` = verified against Apple docs. `[MED]` = strongly indicated but confirm. `⚠️ SPIKE` = must validate on-device before relying on it.
6. **Scaffold exactly as §15 says.** The dev environment (Xcode 26.6, macOS 26.4.1, XcodeGen 2.45.4) was verified on the actual machine on 2026-07-10; §15 gives the target list, build settings, folder tree, and first commands. `project.yml` is the source of truth — regenerate the `.xcodeproj` with `xcodegen generate`, never hand-edit it.
7. **One clock, one coordinate convention, one flip.** All timestamps live on the video timeline (§6); all coordinates live in source pixel space, top-left origin (§5.3 preamble). The Core Image y-flip happens in exactly ONE documented adapter. Violating any of these is the likeliest way to burn a week.
8. **Unit-test the pure math from day one (SP-10).** The spring, clustering, clamp, and transform code is dependency-free — test it before any pixels exist; the tests stay as the regression suite while you tune feel.

---

## 1. PRODUCT DEFINITION

### 1.1 The one thing that must be great
When a non-technical user records a click-through of their app/website and hits Export, the output must look like it was edited by a pro: the camera **glides** into each click and **eases** back out, the cursor moves like butter, and the whole thing sits on a tasteful background. If the motion feels janky next to Screen Studio, the product has failed. **Everything else is secondary to the quality of three motions: zoom easing, cursor smoothing, background craft.**

### 1.2 What it is
- A **local, offline** Mac app. Record → auto-polish → export a file. No account, no upload, no AI credits, no monthly bill.
- Positioned as **"the polished demo recorder you buy once"** — riding Screen Studio's Oct-2025 move to subscription-only.

### 1.3 Target user
People who make demos of **graphical/mouse-driven software**: indie devs shipping launch/changelog clips, SaaS onboarding videos, app walkthroughs, Product Hunt / build-in-public clips. **NOT** terminal/CLI/in-editor demos (those are owned by free tools VHS, asciinema, VS Code Screencast Mode — do not compete there; see §9).

### 1.4 Non-goals for v1 (explicit — say so on the roadmap)
Webcam overlay · multi-clip timeline editing · captions/subtitles/transcription · teleprompter · any AI (silence/filler removal, auto-chapters) · cloud hosting / share links / analytics · team workspaces / multi-seat · Windows build · background-music library · full annotation/blur suite.

---

## 2. MARKET REALITY (why this scope, this price, this channel)

**Validated but brutally saturated.** The mechanic is a solved pattern with 15+ shipping apps. Our modest goal is what makes it sensible.

| App | Price | Distribution | Weakness we exploit |
|---|---|---|---|
| **Screen Studio** (category king) | **Subscription-only** $29/mo (~$108/yr); $229 lifetime **removed Oct 2025** | Direct, notarized, not MAS | Went subscription — the single biggest opening for an anti-sub one-time app |
| **CursorClip** (closest analog) | **$59 one-time** / $20/yr | Direct | Small, thin polish/brand. **Currently ~$1k/mo, ~$6k lifetime (TrustMRR, Jul 2026)** — the realistic ceiling signal |
| **ScreenBuddy** | **$29.99 one-time** | Direct | Brand-new, thin brand; already sitting on the low price point |
| **CleanShot X** | $29 one-time (1yr updates) | Direct + Setapp | Capture/annotation tool, **no cinematic auto-zoom** — different job |
| **FocuSee** | $19.99/mo … $199.99 lifetime | Direct + MS Store | Subscription + AI-credit gating, corporate feel |
| **Tella / Jumpshare** | $12–25/mo | Cloud SaaS | Hosting-first subscription, not a "export a file" tool |
| **Screenity** | Free (GPLv3) | Chrome extension | Browser-bound, annotation-focused, no cinematic camera |

Also in the swarm: ScreenKite, Glideo, Rapidemo, SmoothCapture, Creavit, Rekort, ScreenSnap, Kommodo, ScreenCharm. **Note:** most "best alternative / review" pages in search are SEO content farms run by these apps themselves — the category competes via programmatic comparison-page SEO, a battlefield a newcomer can't win. Route *around* it (§9.3).

---

## 3. ARCHITECTURE (the core design)

**Two stages, decoupled. This is the heart of the app.**

```
 ┌─────────────────────────── STAGE 1: RECORD (live) ───────────────────────────┐
 │                                                                              │
 │  ScreenCaptureKit (SCStream)            CGEventTap (listen-only)             │
 │   ├─ .screen  → CVPixelBuffers  ──┐      ├─ mouse move / click / scroll      │
 │   ├─ .audio   (system)         ───┤      └─ (later) keystrokes               │
 │   └─ .microphone (mic, 15+)    ───┤             │                            │
 │            │                      │             │  stamp each event with     │
 │            ▼                      │             ▼  CMClockGetHostTimeClock    │
 │   AVAssetWriter → raw.mov         │      events.json  (t, point, kind)        │
 │   (H.264/HEVC + audio, RAW,       │      cursor.json  (dense t, point)        │
 │    showsCursor = false)           │                                          │
 └──────────────────────────────────┴──────────────────────────────────────────┘
                      │  a "Project" = raw.mov + events.json + cursor.json + settings
                      ▼
 ┌───────────────────────── STAGE 2: RENDER (offline, re-runnable) ─────────────┐
 │                                                                              │
 │  events → CAMERA PATH ALGORITHM (activity clustering + critically-damped     │
 │           spring ζ=1)  →  per-frame {center, scale}                          │
 │                                                                              │
 │  AVAssetReader → source CVPixelBuffer                                        │
 │        │                                                                     │
 │        ▼   ONE pure compositing fn (shared by preview + export):            │
 │   Core Image layer stack:  background → shadow → screen-card(zoom/pan,       │
 │        rounded corners) → synthetic smooth cursor → click ripple            │
 │        │                                                                     │
 │        ├──▶ EXPORT: CIContext.render → AVAssetWriter → MP4/MOV ; or GIF      │
 │        └──▶ PREVIEW: AVVideoComposition(applyingCIFiltersWithHandler:)       │
 │                      on an AVPlayerItem  (pixel-identical to export)         │
 └──────────────────────────────────────────────────────────────────────────────┘
```

**Why decoupled:** the zoom/cursor/background are all *post-hoc* — computed from the event timeline after recording — so the user can re-edit keyframes and re-export infinitely without re-recording. The single shared compositing function guarantees preview == export.

---

## 4. PLATFORM & STACK DECISIONS (locked)

| Decision | Choice | Rationale |
|---|---|---|
| **Language / UI** | Swift + SwiftUI (AppKit where needed for the editor canvas) | Native craft is the moat + the portfolio value |
| **Min macOS target** | **macOS 15.0 (Sequoia)** | System audio (12.3), **in-SCK microphone (15.0)**, and SCRecordingOutput (15.0) all from one framework. Dropping to 14 later only needs an AVCaptureSession mic fallback. `[HIGH]` |
| **Capture** | ScreenCaptureKit (`SCStream`) | Only non-deprecated path; `CGDisplayStream`/`CGWindowListCreateImage` obsoleted in 15.0 `[HIGH]` |
| **Input events** | `CGEventTap` (listen-only) | Captures mouse + (later) keystrokes with coordinates + timestamps; extends to the keystroke feature. See §5.2 + ⚠️ SPIKE SP-2 `[HIGH]` |
| **Camera path** | Activity clustering → critically-damped spring (ζ=1) | Smooth, no-overshoot, handles rapid re-targeting. §5.3 `[MED]` |
| **Compositor** | Core Image (`CIContext`, Metal-backed) | Every needed op (affine, gradient, mask, gaussian shadow, source-over) is a GPU CIFilter, renders straight to a `CVPixelBuffer`. Raw Metal is the escape hatch only. `[HIGH]` |
| **Export** | `AVAssetReader` → composite → `AVAssetWriter` (+ ImageIO for GIF) | Full control over bitrate/timing `[HIGH]` |
| **Distribution** | **Direct download, Developer ID + notarized. NOT Mac App Store.** | Matches Screen Studio + CleanShot; enables Sparkle auto-update; avoids sandbox-vs-capture friction; keeps 100% (no 30%); own the license/trial flow. §8 `[HIGH]` |
| **Updates** | Sparkle 2 | Standard for direct Mac apps `[HIGH]` |
| **Payments/licensing** | Merchant-of-Record (Lemon Squeezy or Paddle) + swappable license module | MoR handles global VAT; never touch tax yourself. §8.3 `[HIGH]` |

---

## 5. SUBSYSTEM SPECS

### 5.0 Threading & writer-lifecycle map (read before any capture code)

One explicit owner per resource — this prevents the classic SCK/writer races:

| Resource | Owner | Rule |
|---|---|---|
| SCK video buffers | serial queue `capture.video` | handler does ONLY: append to writer input (+ first-frame `startSession`) |
| SCK system-audio buffers | serial queue `capture.audioSys` | append to its own writer input, nothing else |
| SCK mic buffers | serial queue `capture.mic` | append to its own writer input, nothing else |
| `AVAssetWriter` | one recording coordinator (actor/serial queue) creates, starts, finishes it | each `AVAssetWriterInput` is always appended from the same one queue |
| CGEventTap callback | dedicated CFRunLoop thread | stamp `HostClock.now()`, append `{t, point, kind}` to a preallocated buffer, return |
| Camera-path solve + export | offline background task | pure functions, no shared mutable state |
| UI | MainActor | observes coordinator state only |

**Language mode:** build v1 in Swift 5 mode (`SWIFT_VERSION = 5.0`). The CGEventTap C-callback and SCK delegate plumbing fight Swift-6 strict concurrency for zero user-visible benefit; migrate after M3 if desired.

**Writer lifecycle — do exactly this (classic gotchas otherwise):** `[HIGH]`
1. `writer.startWriting()` before `startCapture`.
2. On the **first video sample only**: `writer.startSession(atSourceTime: firstPTS)` — skip this and the file gets a bogus leading gap/duration. Persist `firstPTS` (seconds) into `project.json` as `recordingStartTime`; it is the anchor that converts absolute host-clock event stamps to video-timeline times (§6).
3. Set `expectsMediaDataInRealTime = true` on every input. Append only when `input.isReadyForMoreMediaData`; otherwise drop the frame — blocking the SCK handler queue is worse than a dropped frame.
4. On stop (including `didStopWithError`): `markAsFinished()` on all inputs, then `writer.finishWriting {}` — ALWAYS finalize, so `raw.mov` stays playable even after a mid-record failure.

### 5.1 Capture (ScreenCaptureKit)

**Flow:**
1. **Permissions at first record:** `CGPreflightScreenCaptureAccess()`; if false → `CGRequestScreenCaptureAccess()` (raises the system dialog), then guide user to relaunch. For mic: `AVCaptureDevice.requestAccess(for: .audio)` + `NSMicrophoneUsageDescription` in Info.plist. (Screen Recording has **no** Info.plist key — system-managed.) `[HIGH]`
2. **Enumerate targets:** `SCShareableContent.getShareableContent` → `.displays` / `.windows` / `.applications`. (Optionally present `SCContentSharingPicker` for the native picker.) `[HIGH]`
3. **Build filter:** `SCContentFilter(desktopIndependentWindow:)` to record one app window (the Screen-Studio look) or `SCContentFilter(display:excludingWindows:)` for a full display. `[HIGH]`
4. **Configure `SCStreamConfiguration`:**
   - `width`/`height` = **point size × `SCContentFilter.pointPixelScale`** (Retina ⇒ usually 2×) — **must** do this or capture is soft/low-res. `[HIGH]`
   - `pixelFormat = kCVPixelFormatType_32BGRA`; `minimumFrameInterval = CMTime(value: 1, timescale: 60)` (a cap, not a guarantee); `queueDepth ≈ 6–8`.
   - **`showsCursor = false`** (we draw our own smooth cursor). `[HIGH]`
   - `capturesAudio = true`, `excludesCurrentProcessAudio = true`; on 15+: `captureMicrophone = true`, `microphoneCaptureDeviceID = <default>`.
5. **Stream:** `SCStream(filter:configuration:delegate:)`; `addStreamOutput(_:type:sampleHandlerQueue:)` for `.screen`, `.audio`, `.microphone` **each on its own serial queue**; `startCapture`. In `stream(_:didOutputSampleBuffer:of:)` branch on `SCStreamOutputType`: `.screen` → encoder; `.audio` vs `.microphone` → separate `AVAssetWriter` audio inputs. Implement `SCStreamDelegate.stream(_:didStopWithError:)`.

**Gotchas** `[HIGH]`: `minimumFrameInterval` is a cap — SCK drops duplicate frames when the screen is static, so **use each buffer's `CMSampleBufferGetPresentationTimeStamp()`; never assume evenly-spaced 60fps.** · System audio + mic arrive on the same delegate — branch on `of type`. · After first Screen-Recording grant, app usually needs relaunch. · Mic-in-SCK doesn't exist < 15.0. · Heavy work on the sample-handler queue makes SCK drop frames — keep it thin (see the ownership map in §5.0).

**Audio encoding at record time** `[HIGH]`: write AAC, not PCM passthrough — `AVFormatIDKey: kAudioFormatMPEG4AAC`, 48 kHz, source channel count, ~192 kbps (`AVEncoderBitRateKey`). Smaller files and directly MP4-compatible at export.

**Mid-record disruptions (v1 policy):** if the display configuration changes (resolution switch, monitor unplug) or the captured window closes, **stop the recording gracefully and keep the partial project** — do not attempt live stream reconfiguration in v1. The §5.0 rule ("always finalize the writer") makes the partial `raw.mov` playable.

### 5.2 Input-event timeline (CGEventTap) — drives auto-zoom

**Mechanism:** ONE **listen-only** session tap — `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: <mask>, callback:, userInfo:)`. Mask = mouse down/up (left/right/other), `mouseMoved`, dragged, `scrollWheel`, and (later) `keyDown`/`keyUp`/`flagsChanged`. `[HIGH]`

- **Run loop:** `CFMachPortCreateRunLoopSource` + `CFRunLoopAddSource` on a **dedicated background thread** (`kCFRunLoopCommonModes`). Keep the callback microscopic — heavy work triggers `kCGEventTapDisabledByTimeout` and the OS silently disables the tap; watch for it and re-enable with `CGEventTapEnable`. `[HIGH]`
- **In callback:** read `CGEvent.location` (global, **top-left** origin), keycode via `getIntegerValueField(.keyboardEventKeycode)`, scroll via `getDoubleValueField`. **Immediately stamp with your own clock read** — `CMClockGetTime(CMClockGetHostTimeClock())` (or `mach_absolute_time()`) — because SCK frame PTS ride the same host clock, so event.t and frame PTS are directly comparable. Enqueue to a lock-free buffer; do all camera math later. `[HIGH]`
- **⚠️ Do NOT** use `NSEvent.addGlobalMonitorForEvents` for keystrokes (needs Accessibility, no key location, sandbox-blocked). It's only a fallback for *mouse-only* v1 if SP-2 shows the tap needs a grant we want to avoid.
- **Record-time geometry snapshot:** at `startCapture`, persist the captured content's global rect (`SCContentFilter.contentRect`), `pointPixelScale`, and display origin into `project.json` — the CGEvent→source-pixel mapping (SP-5) then stays a pure function. Events landing outside the captured rect are still stored but flagged `inBounds: false` and ignored by the solver.
- **Window capture + moved windows:** a start-of-recording snapshot drifts if the user drags the recorded window mid-take. Fix cheaply: sample the captured window's frame at ~10 Hz into `window.json` (alongside the cursor sampling) and resolve each event against the nearest frame sample. Display capture doesn't need this.

**Permissions:** mouse-driven zoom may need **no** TCC grant (⚠️ SPIKE SP-2). Keystroke-aware zoom (deferred) needs **Accessibility** (`AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`) since we're non-sandboxed, **or** Input Monitoring (`CGRequestListenEventAccess()`).

**Gotchas** `[HIGH]`: **`CGEventGetTimestamp` units are a trap** — on Apple Silicon it's mach ticks (~41.67 ns), not ns; that's *why* we stamp with our own host-clock read. · Coordinate spaces differ (CGEvent top-left global vs Retina pixel space vs per-display origin) — reconcile carefully (⚠️ SP-5). · Secure Event Input (password fields) suppresses key events — the zoom must tolerate gaps.

### 5.3 Camera-path algorithm (the moat)

**Coordinate convention (single source of truth):** all stored data and all camera math live in **source pixel space, top-left origin, y-down**. Exactly two adapters exist, each in one documented place: (a) record-time — `CGEvent.location` (global points, top-left) → source pixels via the §5.2 geometry snapshot (SP-5); (b) render-time — **Core Image is bottom-left, y-UP**: flip once when building the final composite transform (scale y by −1 + translate by output height), never anywhere else. Scattered ad-hoc flips are the #1 "zoom goes the wrong way" bug. `[HIGH]`

Turn discrete events → a smooth `{centerX, centerY, scale}` signal per output frame:

1. **Activity targets:** sort events; group events with inter-gap `< IDLE_GAP` (~0.6–1.0s) into clusters. Per cluster: `center` = centroid/bbox-center of points; `scale` = zoom (1.6–2.2×, larger for typing on a small region), capped so the viewport stays inside source. Between clusters (idle) insert a target `{center = frame center, scale = 1.0}`. Enforce a **minimum hold/dwell** (~0.8–1.2s) per zoomed target so it doesn't pump.
2. **Sample** the step-target signal at output fps → `targetCX[t]`, `targetCY[t]`, `targetScale[t]`.
3. **Smooth** each component with a **critically-damped spring (ζ=1)**. Per frame `dt`, target `X`, state `(x, v)` — semi-implicit: `v += (-k*(x - X) - 2*sqrt(k)*v)*dt; x += v*dt`. ζ=1 ⇒ no overshoot; mid-flight retargeting handled automatically (why spring beats fixed bezier tweens). Tune `k` for ~0.4–0.7s settle. *(Alternative: precomputed keyframes + quintic ease — simpler, less robust to rapid retargets.)*
4. **Anti-jitter:** min inter-target time; ignore re-centers below a movement threshold; **clamp the zoomed viewport fully inside source bounds after the spring, before building the transform** (or the camera pans past an edge showing empty pixels).
5. **Per frame:** viewport size = `(srcW/scale, srcH/scale)` centered at `(cx, cy)`, clamped. Transform = `translate(-viewport.origin)` then `scale(contentW/viewport.w, contentH/viewport.h)` mapping viewport → output content rect.
6. **Look-ahead (pro feel, free because we render offline):** activate each cluster's target `LEAD ≈ 0.3–0.45s` **before** its first event, so the camera *arrives* as the click happens instead of reacting after it. Live/realtime tools can't do this; post-hoc re-composition can — it's one of the most visible "feels edited by a pro" wins. Implement in M3, make `LEAD` a tuning constant.

**Integrator hardening** `[HIGH]`: run the spring with substeps — `h = min(dt, 1/240)` in a loop — so a variable/dropped frame can't make it ring or explode; clamp `scale ≥ 1` after stepping; clamp the viewport **after** the spring each frame (step 4), never before.

**Reference pseudocode (per output frame):**
```
t       = frameIndex / outputFPS
target  = activeCluster(at: t + LEAD) ?? rest        // rest = {center: srcCenter, scale: 1}
for c in (cx, cy, scale): spring[c].step(toward: target[c], dt, substep ≤ 1/240)
state   = clampViewportInsideSource(state)           // and scale ≥ 1
xform   = translate(contentRect.origin)
        ∘ scale(contentRect.w / viewport.w, contentRect.h / viewport.h)
        ∘ translate(-viewport.origin)
        // then the ONE Core Image y-flip adapter, nowhere else
```

**This whole section is pure math — no device, no pixels.** Write its unit tests first (SP-10): spring never crosses its target (no overshoot), settles within tolerance in ~0.4–0.7s, stays stable under irregular `dt`; clustering honors `IDLE_GAP`/min-hold; the clamp keeps the viewport inside source bounds at every scale.

### 5.4 Compositor (Core Image — one pure function)

`compose(sourceCIImage, cameraState, cursorState, theme) -> CIImage`, layer order:
1. **Background:** full output-size gradient (`CILinearGradient` / `CISmoothLinearGradient`) or solid (`CIConstantColorGenerator`) or user image.
2. **Drop shadow** (under card): dark rounded-rect silhouette, `CIGaussianBlur(radius 24–40)`, offset down a few px, low alpha.
3. **Screen card:** `sourceCIImage.transformed(by: cameraTransform)` placed in the padded content rect; **rounded corners** via `CIBlendWithMask` against a rounded-rect alpha mask (build once with CoreGraphics `CGPath` — safe fallback; `CIRoundedRectangleGenerator` only if ⚠️ SP confirms availability).
4. **Cursor:** map cursor point (source coords) through the **same** `cameraTransform` for position, but composite the pointer sprite at a **FIXED on-screen size** (do NOT scale with zoom — matches Screen Studio). Smooth the cursor track with the same spring / Catmull-Rom. Optional click ripple (expanding fading circle at click times). `CISourceOverCompositing`.

**Rules** `[HIGH]`: build **ONE** Metal-backed `CIContext` and reuse it (creation is expensive). Pass explicit `colorSpace` (sRGB) to `render(...)` or colors shift. Remember Core Image is y-UP — the single flip adapter lives in the transform build (§5.3 preamble). Content-only zoom (background stays full-bleed) looks cleaner (⚠️ design decision, prototype both).

**Cursor sprite:** ship a bundled vector/@2x arrow asset and composite that — do **not** read the live `NSCursor` at render time (render is offline; the live cursor is meaningless then). Recording cursor-*type* changes (I-beam, pointer, resize) is a v1.1 nicety, not v1.

**Trial watermark for free:** because preview and export share this one compose fn, the trial watermark (§8.4) is just one extra top layer added when no valid license is present — the trial user's preview automatically shows exactly what export will produce.

### 5.5 Export

- **Decode:** `AVAssetReader` + `AVAssetReaderTrackOutput` (video track, `kCVPixelFormatType_32BGRA`, `kCVPixelBufferMetalCompatibilityKey: true`); loop `copyNextSampleBuffer()` → `CMSampleBufferGetImageBuffer` + PTS. Run **offline / faster-than-realtime.**
- **Encode:** `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`; `CIContext.render(composited, to: outPixelBuffer, ...)`; pull `outPixelBuffer` from `adaptor.pixelBufferPool` (reuse — don't allocate per frame); `adaptor.append(_:withPresentationTime:)` respecting `input.isReadyForMoreMediaData` / `requestMediaDataWhenReady`. Codec `AVVideoCodecType.h264` or `.hevc`; container `.mp4`/`.mov`.
- **Audio:** second reader-output → second writer-input (pass-through or AAC) — **or narration is silently lost.** `[HIGH]`
- **Output timeline:** `writer.startSession(atSourceTime: .zero)` and re-base output PTS so the exported file starts at zero (the project's video timeline, minus `trimIn`), independent of the raw capture's host-clock PTS.
- **GIF:** reuse the compositing fn at capped fps (~15–20) + capped dimensions; `CIContext.createCGImage` → `CGImageDestinationCreateWithURL(url, UTType.gif.identifier, N, nil)` → `CGImageDestinationAddImage` with `kCGImagePropertyGIFDelayTime` → set `kCGImagePropertyGIFLoopCount: 0` → `CGImageDestinationFinalize`. **Warn** on size (256-color, balloons at high res). **Delay-time trap** `[HIGH]`: browsers clamp GIF frame delays below ~0.02s (many force them to 0.1s) — use delays ≥ 0.03s and round to hundredths, or playback speed silently breaks in Chrome/Safari.

### 5.6 Preview (same math, zero drift)

Attach `AVVideoComposition(asset:applyingCIFiltersWithHandler:)` to the `AVPlayerItem`; in the handler call the **same** `compose(...)` with `request.sourceImage` + `cameraState(at: request.compositionTime)` → `request.finish(with: image, context: ciContext)`. Guarantees preview == export.

---

## 6. DATA MODEL — the "Project" (`.reelproj` bundle)

A recording is a **document package** (folder shown as a file):
```
MyDemo.reelproj/
  raw.mov            # untouched high-res capture (video + system audio + mic tracks)
  events.json        # [{ t, x, y, kind: "click"|"scroll"|"drag"|"key", inBounds }]
  cursor.json        # dense [{ t, x, y }] sampled during recording (~60 Hz)
  window.json        # window-capture only: [{ t, frame }] at ~10 Hz (§5.2 moved-window fix)
  project.json       # schemaVersion (=1 from day one) · recordingStartTime · geometry snapshot
                     #   (contentRect, pointPixelScale, sourceWidth/Height, displayOrigin)
                     #   · trimIn/trimOut · theme, padding, cornerRadius, shadow, aspect,
                     #   fps, codec · user keyframe overrides (added/moved/deleted zoom targets)
  thumbnail.png
```

**Time convention** `[HIGH]`: every stored `t` is on the **video timeline** — seconds since the first video frame. Events are stamped with the host clock during capture (§5.2) and normalized by subtracting `recordingStartTime` (= the first video sample's PTS, captured in §5.0 step 2) when the JSON is written. This keeps every downstream consumer (solver, compositor, preview, export) clock-free.

**Space convention:** coordinates in **source pixel space**, top-left origin (§5.3 preamble), with the backing scale recorded in the geometry snapshot. Keeping `raw.mov` untouched is what makes re-editing + re-export infinite and lossless. Include `schemaVersion` checks when opening — refuse-newer, migrate-older.

---

## 7. PERMISSIONS & ONBOARDING UX

At first record, a friendly onboarding pane that:
1. Checks `CGPreflightScreenCaptureAccess()` → if not granted, `CGRequestScreenCaptureAccess()`, deep-link to **System Settings ▸ Privacy & Security ▸ Screen Recording**, and handle the "granted but needs relaunch" state.
2. If mic recording is on: request Microphone access.
3. If/when keystroke-aware zoom ships: separate Accessibility (or Input Monitoring) onboarding.
4. **Tell the user about the macOS 15 recurring (monthly) Screen-Recording re-confirmation** — it's an OS behavior, not a bug; there's no indie-obtainable way to disable it (MDM-only). Handle it gracefully. `[HIGH]`

**Critical:** TCC grants are bound to code-signing identity. Ship a **stable Developer ID identity** or every build/update resets Screen Recording. `[HIGH]`

---

## 8. DISTRIBUTION, LICENSING, UPDATES

### 8.1 Distribution — direct, notarized `[HIGH]`
Xcode archive → `codesign` with **Developer ID Application + Hardened Runtime** → package `.dmg` → `xcrun notarytool submit --keychain-profile …` → `xcrun stapler staple` → host the `.dmg`. Every nested binary (Sparkle XPC, helpers) must be signed with the same Developer ID + secure timestamp or notarization fails. **No sandbox** (direct distribution doesn't require it) → full capture freedom.

### 8.2 Auto-update — Sparkle 2 `[HIGH]`
`bin/generate_keys` once → embed `SUPublicEDKey` + `SUFeedURL` in Info.plist → host `appcast.xml` + signed archives (S3/CDN) → `generate_appcast` each release. Pin the Sparkle version (⚠️ SP-9).

### 8.3 Licensing — MoR + swappable module `[HIGH]`
Sell via a **Merchant of Record** so you never handle VAT/sales-tax. Default **Lemon Squeezy** (turnkey license-key API: generate on purchase webhook; app validates/activates via API with an activation-count limit + offline grace period). **Design the license layer so the payment provider is swappable** — Lemon Squeezy's post-acquisition longevity is a risk; **Paddle** is the durable fallback (build your own key issuance on top). Avoid raw Stripe (you'd owe global tax). Decide **lifetime updates vs a version window** (many indies sell "1 year of updates"); encode it in the license + appcast check.

### 8.4 Trial
**Watermark-on-export**, removed on purchase (every trial export becomes marketing) — better than a time limit for a demo tool. Or a 7–14 day full-feature trial. No free tier (cannibalizes).

---

## 9. GO-TO-MARKET

### 9.1 Positioning
**"The polished demo recorder you buy once."** Native · offline · no account · no cloud · no AI credits · no monthly bill — pay once, export forever. Honest caveat: CursorClip ($59) and ScreenBuddy ($29.99) already say this — so the wedge is **execution quality on the three motions** + a specific flavor (indie devs / build-in-public / changelog & launch clips) marketed where those people gather, *not* comparison-page SEO.

### 9.2 Pricing
**One-time $39 launch → $49 standard.** Don't validate the $29.99 race-to-the-bottom; $59 is stiff for an unknown brand. $49 leaves room for a paid 2.0 upgrade later (CleanShot model). No subscription — it's the whole differentiation.

### 9.3 Launch channels (priority order)
1. **Show HN** — a screen-demo tool *demos itself*; the landing-page hero video is the pitch (make it with the app).
2. **Product Hunt** — weekend launch (lower upvote bar) for a badge without being buried.
3. **r/macapps, r/SideProject, r/apple** — receptive to one-time native "anti-subscription" apps.
4. **X / build-in-public / indie-hacker circles** — your best-fit users; routes *around* the SEO war.
5. **Setapp** (later) — the one recurring channel that doesn't contradict one-time positioning.

### 9.4 Realistic revenue (be skeptical)
Screen Studio's ~$30k month-one was 2023 first-mover timing — **that window is closed.** Honest comp: CursorClip ~$1k/mo (~$6k lifetime) after real effort. Expect a **spiky launch** (a great demo on HN/PH front page ⇒ maybe a few $k in launch month) **decaying to ~$200–$1,500/mo** if the product is good and you keep marketing. Your "few hundred/mo + portfolio" goal is realistic, not guaranteed, and needs ongoing marketing — not just shipping. As a portfolio piece (native Swift, ScreenCaptureKit, real-time metadata capture, custom easing, Metal-accelerated export) it's excellent **regardless of revenue.**

---

## 10. PROTOTYPE SPIKES — DO THESE FIRST (⚠️ each is an afternoon)

Building these before production code is what keeps this plan hallucination-free. **Each spike either confirms an assumption or changes the design.**

| ID | Spike | Why it matters |
|---|---|---|
| **SP-0** | Bare `SCStream` capturing one window at Retina 60fps → write `raw.mov` with `AVAssetWriter`; confirm crisp resolution (pointPixelScale applied) and that variable-fps PTS encode correctly. | Proves the capture spine. |
| **SP-1** | Confirm system audio + mic both record and land on separate tracks; verify `NSMicrophoneUsageDescription` + whether `captureMicrophone=true` alone triggers the mic prompt or needs `AVCaptureDevice.requestAccess`. | A/V correctness. |
| **SP-2** | Does a listen-only `CGEventTap` for **mouse-only** events fire with **no** TCC grant on macOS 15? Measure. If it needs Input Monitoring and that's friction, fall back to `NSEvent` global mouse monitor for v1. | Decides v1 permission surface. |
| **SP-3** | Confirm `CGEvent` timestamps (stamped via `CMClockGetHostTimeClock`) and SCK `CMSampleBufferGetPresentationTimeStamp` share one clock — subtracting yields correct offsets (watch epoch/sign). | Event↔frame sync = the whole auto-zoom. |
| **SP-4** | Measure Core Image throughput end-to-end (decode→composite→encode) on a 4K/60 recording. Faster-than-realtime? If not, evaluate the Metal path. | Confirms compositor choice. |
| **SP-5** | Map `CGEvent.location` (top-left global) → captured window/display **pixel** space under Retina + multi-display. | Zoom targets the wrong spot if wrong. |
| **SP-6** | Verify `CIRoundedRectangleGenerator` / `CISmoothLinearGradient` availability + exact param keys on target OS; else use CoreGraphics mask + `CILinearGradient`. | Avoids coding to a wrong filter. |
| **SP-7** | End-to-end: notarized Developer ID build actually raises the right prompts and captures on a clean macOS 15 machine (+ test the monthly re-confirmation). **NOTE:** the dev machine runs macOS 26.x — everyday spikes validate *current*-OS behavior only; the 15.0 min-target claim is proven only by running this on an actual macOS 15 VM/machine. | Distribution reality. |
| **SP-8** | Validate the chosen MoR (Lemon Squeezy/Paddle) license-key generate + offline-grace validate flow against the live API. | Licensing before launch. |
| **SP-9** | Pin exact Sparkle 2 version + its deployment floor; validate non-sandboxed XPC config. | Update channel. |
| **SP-10** | Unit-test the pure camera math **before touching pixels** (no device needed): spring never overshoots, settles in ~0.4–0.7s, stable under irregular `dt`; clustering honors `IDLE_GAP`/min-hold; viewport clamp holds at every scale (§5.3). | Locks the moat's math in an afternoon; stays as the regression suite while tuning feel. |

---

## 11. MILESTONES (each shippable/demoable, with acceptance criteria)

- **M0 — Scaffold + Spikes (§10, §15).** Scaffold per §15 (XcodeGen; `Reel` + `ReelSpikes` + `ReelTests` targets), then run the spikes inside the `ReelSpikes` app. *Accept:* project builds; SP-10 unit tests green; SP-0…SP-6 pass or design updated to match findings.
- **M1 — Capture core.** Record a window/display to `raw.mov` (video + system audio + mic), `showsCursor=false`, permission onboarding. *Accept:* crisp Retina 60fps file with audio; correct PTS.
- **M2 — Event timeline.** `CGEventTap` writes `events.json` + `cursor.json` synced to video; the `.reelproj` package is created. *Accept:* clicks land at correct video timestamps + pixel positions (validates SP-3/SP-5).
- **M3 — Auto-zoom render (the moat).** Camera-path algorithm (incl. §5.3 look-ahead) + Core Image compositor (zoom/pan + screen card only) → export MP4. *Accept:* camera glides into clicks and eases out with **no overshoot/jitter**; the zoom *arrives* on the click, not after it; side-by-side against a Screen Studio clip looks comparable in motion smoothness; SP-10 tests still green after feel-tuning.
- **M4 — Background & cursor polish.** Gradient/solid/image backgrounds, padding, rounded corners, drop shadow, fixed-size **smooth synthetic cursor**, click ripple, aspect presets. *Accept:* zero-edit default output looks pro.
- **M5 — Export suite.** MP4 (H.264/HEVC), MOV, GIF with presets; audio preserved. *Accept:* all formats correct; GIF size-warned.
- **M6 — Editor UI & live preview.** SwiftUI editor: scrubbable `AVPlayer` preview (shared compositing fn), editable/add/delete zoom keyframes, trim, theme controls. *Accept:* preview == export pixel-identical; user can retune a zoom and re-export.
- **M7 — Distribution & licensing.** Developer ID + notarize + `.dmg`, Sparkle appcast, MoR license (trial→paid, watermark removal). *Accept:* clean-machine install works; trial→license→update round-trip works (SP-7/8/9).
- **M8 — Launch.** Landing page (hero video made with the app), Show HN + PH weekend + Reddit/X. *Accept:* shipped.

**Rough solo timeline:** M0–M3 the hard/slow part (the render/animation craft is where Screen-Studio-grade quality is won or lost); M4–M6 the bulk of polish; M7–M8 a couple weeks. Ballpark **2–4 months** to a credible paid v1; a rough clone in weeks that *looks* rough (don't ship that).

---

## 12. API APPENDIX (verified — use verbatim; do not invent signatures)

**Capture — ScreenCaptureKit** ([docs](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration), [capture guide](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)):
`SCShareableContent.getShareableContent` · `SCDisplay` · `SCWindow` · `SCRunningApplication` · `SCContentFilter(display:excludingWindows:)` · `SCContentFilter(desktopIndependentWindow:)` · `SCContentFilter.pointPixelScale` · `SCContentFilter.contentRect` · `SCStreamConfiguration` {`width`,`height`,`pixelFormat`,`minimumFrameInterval`,`showsCursor`,`capturesAudio`,`excludesCurrentProcessAudio`,`sampleRate`,`channelCount`,`captureMicrophone`(15+),`microphoneCaptureDeviceID`(15+),`queueDepth`} · `SCStream(filter:configuration:delegate:)` · `SCStream.addStreamOutput(_:type:sampleHandlerQueue:)` · `startCapture`/`stopCapture`/`updateConfiguration`/`updateContentFilter` · `SCStreamOutput.stream(_:didOutputSampleBuffer:of:)` · `SCStreamOutputType` {`.screen`,`.audio`,`.microphone`(15+)} · `SCStreamDelegate.stream(_:didStopWithError:)` · `SCContentSharingPicker` · `SCRecordingOutput`(15+) · `CGPreflightScreenCaptureAccess()` · `CGRequestScreenCaptureAccess()` · `CMSampleBufferGetImageBuffer` · `CMSampleBufferGetPresentationTimeStamp` · `AVCaptureDevice.requestAccess(for:)` · `kCVPixelFormatType_32BGRA`

**Input events — CGEventTap** ([tapCreate](https://developer.apple.com/documentation/coregraphics/cgevent), [listen access](https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess())):
`CGEvent.tapCreate(tap:place:options:eventsOfInterest:callback:userInfo:)` · `CGEventTapLocation.cgSessionEventTap` · `CGEventTapPlacement.headInsertEventTap` · `CGEventTapOptions.listenOnly` · `CGEventMask` · `CGEventType` {`.leftMouseDown`/`.leftMouseUp`/`.rightMouseDown`/`.rightMouseUp`/`.otherMouseDown`/`.otherMouseUp`/`.mouseMoved`/`.leftMouseDragged`/`.scrollWheel`/`.keyDown`/`.keyUp`/`.flagsChanged`} · `CGEventTapEnable(tap:enable:)` · `kCGEventTapDisabledByTimeout` · `kCGEventTapDisabledByUserInput` · `CFMachPortCreateRunLoopSource` · `CFRunLoopAddSource` · `kCFRunLoopCommonModes` · `CGEvent.location` · `CGEvent.getIntegerValueField(_:)` + `CGEventField.keyboardEventKeycode` · `CGEvent.getDoubleValueField(_:)` + `.scrollWheelEventDeltaAxis1/2` · `CGPreflightListenEventAccess()` · `CGRequestListenEventAccess()` · `AXIsProcessTrustedWithOptions(_:)` + `kAXTrustedCheckOptionPrompt` · `CMClockGetHostTimeClock()` · `CMClockGetTime(_:)` · `mach_absolute_time()` · `mach_timebase_info(_:)` · `CMTimeGetSeconds(_:)`

**Render/export — AVFoundation + Core Image + ImageIO** ([AVAssetWriter](https://developer.apple.com/documentation/avfoundation/avassetwriter), [CIContext](https://developer.apple.com/documentation/coreimage/cicontext), [applyingCIFilters](https://developer.apple.com/documentation/avfoundation/avvideocomposition/init(asset:applyingcifilterswithhandler:))):
`AVURLAsset` · `AVAssetReader` · `AVAssetReaderTrackOutput.copyNextSampleBuffer()` · `AVAssetWriter` {`startWriting()`,`startSession(atSourceTime:)`,`finishWriting(completionHandler:)`} · `AVAssetWriterInput` {`isReadyForMoreMediaData`,`requestMediaDataWhenReady(on:using:)`,`expectsMediaDataInRealTime`,`markAsFinished()`} · `AVFormatIDKey` + `kAudioFormatMPEG4AAC` · `AVSampleRateKey` · `AVNumberOfChannelsKey` · `AVEncoderBitRateKey` · `AVAssetWriterInputPixelBufferAdaptor` {`.pixelBufferPool`,`.append(_:withPresentationTime:)`} · `AVVideoCodecKey` · `AVVideoCodecType.h264`/`.hevc` · `AVVideoCompressionPropertiesKey` · `AVVideoAverageBitRateKey` · `AVFileType.mp4`/`.mov` · `CVPixelBuffer` · `CVPixelBufferPool` · `kCVPixelBufferMetalCompatibilityKey` · `CIContext(mtlDevice:)` · `CIContext.render(_:to:bounds:colorSpace:)` · `CIContext.createCGImage(_:from:)` · `CIImage.transformed(by:)` · `CGAffineTransform` · `CISourceOverCompositing` · `CIBlendWithMask` · `CIGaussianBlur` · `CIConstantColorGenerator` · `CILinearGradient` · `CISmoothLinearGradient` · `CIRoundedRectangleGenerator`(⚠️SP-6) · `AVVideoComposition(asset:applyingCIFiltersWithHandler:)` · `AVAsynchronousCIImageFilteringRequest` · `CGImageDestinationCreateWithURL` · `CGImageDestinationAddImage` · `CGImageDestinationFinalize` · `UTType.gif` · `kCGImagePropertyGIFDictionary` · `kCGImagePropertyGIFDelayTime` · `kCGImagePropertyGIFLoopCount`

**Distribution/updates:** `xcrun notarytool submit` · `xcrun notarytool log` · `xcrun stapler staple` · `codesign --options runtime` (Hardened Runtime) · Developer ID Application cert · Sparkle: `SPUStandardUpdaterController`, `bin/generate_keys`, `generate_appcast`, Info.plist `SUFeedURL` + `SUPublicEDKey`.

**Deprecated — DO NOT USE:** `CGDisplayStream`/`CGDisplayStreamCreate` (obsoleted 15.0) · `CGWindowListCreateImage` · `AVCaptureScreenInput` · `NSEvent.addGlobalMonitorForEvents` for keystrokes (Accessibility-gated, no key location).

---

## 13. OPEN DECISIONS FOR THE HUMAN (Sid)

1. **Name + branding.** "Reel" is a placeholder. Almost every obvious name is taken (Glideo, ScreenKite, ScreenBuddy, CursorClip, ScreenSnap, Kommodo, ScreenCharm…). Pick one and clear it: trademark search + `.app`/`.com` domain + Mac-app-name collision.
2. **Min OS: 15.0 (simplest, recommended) vs 14.0** (wider reach, +AVCaptureSession mic fallback).
3. **Keystroke-aware zoom in v1 or defer?** Defer is recommended (mouse-only avoids Accessibility friction).
4. **Trial model:** watermark-on-export (recommended) vs time-limited.
5. **License scope:** lifetime updates vs "1 year of updates."
6. **MoR:** Lemon Squeezy (turnkey, longevity risk) vs Paddle (durable, more work).
7. **Price:** confirm $39 launch / $49 standard.

---

## 14. SOURCES (key)
Screen Studio pricing/subscription shift · CursorClip [pricing](https://cursorclip.com/pricing/) + [verified revenue](https://trustmrr.com/startup/cursorclip) · [CleanShot X](https://cleanshot.com/pricing) · [ScreenBuddy](https://screenbuddy.xyz/) · [Screenity](https://github.com/alyssaxuu/screenity) · [Kap](https://github.com/wulkano/kap) · [VHS](https://github.com/charmbracelet/vhs) · [asciinema](https://docs.asciinema.org/how-it-works/) · [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) · [MAS vs direct](https://www.jessesquires.com/blog/2021/06/02/to-distribute-in-the-mac-app-store-or-not/) · ScreenCaptureKit / CoreGraphics / AVFoundation / Core Image / ImageIO Apple docs (linked inline in §12).

---

## 15. IMPLEMENTATION KICKOFF (scaffold spec — environment verified on the dev machine 2026-07-10)

**Environment (checked, real — not assumed):** Xcode 26.6 (build 17F113) · macOS 26.4.1 · XcodeGen 2.45.4 at `/opt/homebrew/bin/xcodegen`. ⚠️ Dev OS is 26.x while min target is 15.0 — see the SP-7 note about what that does and doesn't validate.

**Scaffold with XcodeGen.** `project.yml` is the source of truth; regenerate with `xcodegen generate`; never hand-edit the `.xcodeproj`.

**Targets:**
- `Reel` (macOS app) — the product.
- `ReelSpikes` (macOS app) — the M0 harness: one window, a button per spike, results logged to the window + console. It compiles the production helper files it exercises (`HostClock`, `CapturePermissions`, models, camera math) so spike findings land directly in real modules, not throwaway code.
- `ReelTests` (unit tests) — SP-10 math tests live here from day one and run in the `Reel` scheme's test action.

**Key build settings (all targets):** `MACOSX_DEPLOYMENT_TARGET = 15.0` · `SWIFT_VERSION = 5.0` (rationale §5.0) · `ENABLE_HARDENED_RUNTIME = YES` (notarization, §8.1) · `ENABLE_APP_SANDBOX = NO` (direct distribution, §4) · bundle prefix `com.neeklabs` (provisional — Open Decision #1).
**Entitlements (both apps):** `com.apple.security.device.audio-input = true` (hardened runtime requires it for mic).
**Info.plist:** `NSMicrophoneUsageDescription` present; **no** key exists for Screen Recording (system-managed TCC, §5.1).

**Folder layout (mirrors §3 — one folder per subsystem):**
```
DemoRecorder/
  BUILD_PLAN.md
  project.yml
  Reel/
    App/            ReelApp.swift (SwiftUI @main)
    UI/             ContentView + editor views (M6)
    Capture/        CapturePermissions.swift, ScreenRecorder.swift        (§5.1)
    Events/         HostClock.swift, EventTapRecorder.swift               (§5.2)
    CameraPath/     CriticallyDampedSpring.swift, CameraPathSolver.swift  (§5.3 — pure, tested)
    Compositing/    Compositor.swift — the ONE pure compose fn            (§5.4)
    Export/         Exporter.swift                                        (§5.5)
    Preview/        PreviewComposition.swift                              (§5.6)
    Model/          ReelProject.swift (.reelproj IO, Codable)             (§6)
  Spikes/           SpikesApp.swift + one file per spike (SP0…SP6)
  Tests/            Spring / clustering / clamp / transform tests (SP-10)
```

**First commands:**
```bash
cd ~/Desktop/DemoRecorder
xcodegen generate
xcodebuild -project Reel.xcodeproj -scheme Reel build        # must be green before anything else
xcodebuild -project Reel.xcodeproj -scheme Reel test         # SP-10 suite
```

**Build order:** scaffold → SP-10 tests (pure math, day one) → SP-0…SP-6 inside `ReelSpikes` → then M1+ per §11. Do **not** start M1 before SP-0/SP-1 pass.

---
*Plan generated from adversarially-verified research (Apple documentation + live competitor teardowns). Confidence tags and ⚠️ SPIKE markers indicate what is verified vs what must be validated on-device before relying on it. Revised 2026-07-10 (implementation-hardening pass: §5.0 threading/writer map, coordinate + time conventions, look-ahead, moved-window fix, GIF delay trap, SP-10, §15 kickoff spec). Build the spikes in §10 first.*
