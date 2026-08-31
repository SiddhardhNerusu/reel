# Reel — Product & Revamp Brief

> **For:** a design + product revamp pass.
> **What this is:** everything you need to know about Reel — what it is, what's built, what's broken, and where it's going — plus a design brief (every screen/state to redesign) and a research-backed functionality roadmap. Written 2026-07-12.
>
> **One-line:** Reel is a native macOS app that records your screen and *automatically* turns the raw footage into a polished product demo — the camera glides and zooms to whatever you click, the cursor moves like butter, dead air is cut, and it all sits on a tasteful background. **Record → it's already edited → export.** One-time purchase, offline, no account, no AI credits, no subscription.

---

## 0. TL;DR of what needs to happen

1. **The recording is a stub.** Today the "record" button captures a hardcoded 6 seconds then stops. That's a test harness, not a recorder. It needs real **start / stop / pause / unlimited-duration** capture. This is why it "cuts off at 5 seconds" and feels no better than macOS screen record.
2. **The auto-zoom is naive.** It springs the camera to the raw click *coordinate* with fixed easing. Pros zoom to the **actual UI element you clicked**, by the **right amount for its size**, and **arrive before the click lands**. That's the whole difference between "awkward" and "cinematic."
3. **The editing is thin.** Backgrounds, aspect, trim, one auto-zoom toggle. It needs the real set: smart auto-zoom you can retune, cursor effects, audio cleanup / silence removal, click emphasis, cuts/speed, captions.
4. **All the "intelligence" is free and on-device.** No LLM, no API cost. Apple's Accessibility, Vision, AVFoundation, Speech, and Accelerate frameworks + pure math do all of it (feasibility-verified — see §6).
5. **The UI needs a cohesive premium revamp** across every screen and state (§4).

---

## 1. What Reel is

### 1.1 The product
A **local, offline** Mac app. You hit record, click through your app or website, hit stop — and Reel has already produced a Screen-Studio-grade demo video: auto zoom/pan to each interaction, a smooth synthetic cursor, a padded gradient background with rounded corners and a soft shadow, dead air removed. Export MP4 / GIF / MOV, or copy straight to the clipboard to paste into Slack / a DM / a tweet.

### 1.2 Who it's for
People who make demos of **graphical, mouse-driven software**: indie devs shipping launch/changelog clips, SaaS onboarding videos, app walkthroughs, Product Hunt / build-in-public clips. **Not** terminal/CLI demos (owned by free tools). Not talking-head/webcam production. Not cloud collaboration.

### 1.3 Positioning & price (research-backed)
- **"The polished demo recorder you buy once."** Native · offline · no account · no cloud · no AI credits · no monthly bill.
- Rides Screen Studio's 2026 move to **subscription-only** ($29/mo). The wedge is the **anti-subscription promise** + a genuinely "record-and-it's-already-edited" experience.
- **Price: $49 one-time** (launch $39). Comps: CursorClip $59, Screen Charm $79, SmoothCapture ~$49, ScreenBuddy $29.99.
- **~90% of buyers in this category cite auto-zoom as the reason they bought.** Cursor smoothing is #2. Automatic audio/silence cleanup is the best under-served upsell. So: **the auto-edit *is* the product.** Everything else is table stakes.

### 1.4 The moat
Not the feature list (15+ apps do the mechanic). The moat is **execution quality on three motions** — zoom easing, cursor smoothing, background craft — plus **how intelligently it decides what to zoom to and when.** That intelligence, done well and for free on-device, is the differentiator.

---

## 2. Architecture (the load-bearing design — keep this)

**Two stages, decoupled:**

1. **RECORD (live):** capture raw screen video to disk *untouched*, and — in parallel — a **synchronized event timeline** (every mouse move / click / scroll / keystroke, timestamped on the same clock as the video via `CGEventTap`). Screen video via **ScreenCaptureKit**; audio (system + mic) into the same file.
2. **RENDER (offline, re-runnable):** from the event timeline, compute a smooth camera path + cursor path + cuts, then re-composite every frame through **one pure compositing function** shared by the live preview and the export — so preview == export, pixel-identical.

**Why it matters:** the zoom/cursor/cuts/background are all *post-hoc* — computed after recording — so the user can re-edit and re-export infinitely without re-recording, and (crucially) the render pass **knows the future**, which is what enables "arrive before the click" look-ahead. This architecture is already built and proven; the revamp extends it, it doesn't replace it.

---

## 3. Current state (honest)

**Built and proven (verified against real exported files):**
- The whole **Stage-2 render pipeline**: camera solve (critically-damped spring + look-ahead), compositor (background gradient/solid, padded rounded card, drop shadow, fixed-size synthetic cursor, click ripple), export to MP4/GIF. Preview == export proven. ~40 Swift files, unit-tested pure math, all green.
- A working **editor** ("Studio"): live scrubbable preview, 5 background themes, aspect presets (Source/16:9/4:3/1:1/9:16), an auto-zoom toggle, a **filmstrip trim timeline** with draggable in/out handles + playhead, export to MP4/GIF, copy-to-clipboard, keyboard shortcuts (Space, ←/→, ⌘E).
- A **launcher** with permission onboarding and a "Render a sample" path that produces a full demo with no recording (great for testing + as the landing-page hero).
- A **design system** (dark charcoal, single violet accent, depth/shadows, hover states).

**Stubbed / broken / thin (the work):**
- ❌ **Recording is a fixed 6-second test.** No start/stop, no pause, no unlimited duration, no area selection, no hotkeys, no countdown. *This is the biggest gap.*
- ❌ **Auto-zoom is "blind."** It targets the raw click XY with a fixed zoom amount. No knowledge of *what* was clicked, no size-aware zoom, no skip-when-already-large, weak look-ahead. Reads as "awkward."
- ❌ **No audio editing** (no silence/dead-air removal, no auto-speed of idle).
- ❌ **No cursor smoothing beyond the basic spring** (no one-euro de-jitter, no click-hold).
- ❌ **No step/scene detection, no captions.**
- ❌ **No manual zoom-keyframe editing** (add/move/delete/retune individual zooms on the canvas/timeline).
- ⚠️ **Permission onboarding** works but is the least-polished screen (being fixed).

---

## 4. DESIGN BRIEF (this is the part for the design revamp)

### 4.1 Brand personality
Premium, calm, confident **creative tool** — closer to Linear / Raycast / Screen Studio than to a utility. It should feel **crafted**, because the entire pitch is craft. Restrained, not flashy. Indie and trustworthy ("nothing leaves your Mac"). The product does the hard work *for* you, so the UI should feel effortless and quiet, letting the preview be the star.

### 4.2 Visual language (current baseline — evolve, don't discard)
- **Dark, deep charcoal** ground (`#17181C`-ish) with a faint accent glow for depth.
- **One accent: violet** (`~#7C6CF5`) used sparingly — primary actions, selection, the record affordance. Semantic red only for the live "recording" state.
- **SF Pro** system type; clear hierarchy (large bold titles, medium section labels with letter-spacing, muted secondary text).
- **Depth via materials + soft shadows**, rounded cards (10–16px), generous spacing on an 8pt grid.
- **Theme-aware** is not required (it's a committed dark creative-tool look), but keep contrast legible.
- The current app already uses these tokens — the revamp should **raise the craft and cohesion**, not reinvent the palette (unless you have a stronger idea).

### 4.3 Every screen & state to design
Design each of these as a considered, cohesive set. States marked ⚠️ are currently weak.

**A. Launcher / Home**
- **A1 — First run / permission** ⚠️ *(currently the weakest screen)*. A warm, confidence-building "one quick permission" moment: explain *why* (record the screen), reassure (only permission, nothing leaves the Mac), and make the 2-step flow obvious (Open Settings → enable Reel → relaunch). Needs a hero-quality treatment, not a plain card.
- **A2 — Ready to record** (permission granted): choose **source** (whole display / a window / an area/region / a specific app), pick display, then a big confident **Record** button. Consider live thumbnails of sources. A secondary "Try a sample."
- **A3 — Area selection overlay**: a full-screen dimmed overlay to drag-select a capture region (new — needs design).
- **A4 — Recording state**: minimal, out-of-the-way. A compact floating **recorder bar** (record dot + elapsed time + pause + stop + a quick "restart"), ideally detached from the main window so it doesn't get captured. Optional live click/zoom indicator.
- **A5 — Post-record / processing → ready**: the moment the recording finishes and Reel auto-produces the edit — this should feel magical. Then land in the editor.

**B. The Editor ("Studio")** — the core workspace
- **B1 — Canvas**: the framed live preview floating on a calm canvas (already good — floating aspect-correct card, soft shadow). Keep this as the hero.
- **B2 — Inspector**: grouped controls — Background (swatches + custom image/color), Aspect, **Auto-zoom** (intensity/on-off/style, not just a toggle), Cursor (size, smoothing, click effects), Padding/Inset, Corner radius, Shadow. Needs room to grow without feeling cluttered.
- **B3 — Timeline** (bottom, full-width): the filmstrip with trim handles + playhead exists. **Extend it** into a proper edit surface: a **zoom-keyframe track** showing each auto-generated zoom as an editable block (drag to move, resize to change duration, click to retune target/scale, add/delete), an **audio waveform** lane, and **cut/gap** markers. Snapping, ripple, undo/redo.
- **B4 — Direct manipulation on the canvas**: drag to reposition a zoom's target, resize the zoom region — so editing a zoom feels physical, not like editing numbers.
- **B5 — Export / share moment**: the format + preset picker (MP4/GIF/MOV, resolution, fps), progress, and the **success moment** (Copy to clipboard / Reveal / Save) — this is high-emotion, make it delightful. (A basic toast exists.)

**C. System / lifecycle**
- **C1 — Empty states** (no recording yet, in the editor before content).
- **C2 — Settings / preferences** (hotkeys, default background, export defaults, countdown length, camera on/off).
- **C3 — Trial → purchase / license** (watermark-on-export trial; a tasteful "remove watermark / buy once" moment — not nagware).
- **C4 — Onboarding first-run tour** (optional, light).

### 4.4 Design principles for this product
- **The preview is the thesis.** Let the composited demo be the most beautiful thing on screen; keep chrome quiet.
- **State reads at a glance** — recording vs idle vs exporting should be unmistakable (color, motion, a pill).
- **What's interactive looks interactive**; direct manipulation over number-fiddling.
- **Effortless > powerful.** The auto-edit does 90%. Controls are for *refining*, not *assembling*. Don't design a Premiere.
- **Motion with intent** — micro-interactions that feel considered (hover lifts, the export success beat), never gratuitous.

---

## 5. FUNCTIONALITY ROADMAP (research-backed)

Priority tags: **[MUST]** core to a credible v1 · **[SHOULD]** strong differentiators · **[NICE]** later.

### 5.1 Recording core — turn the stub into a real recorder
- **[MUST] Unlimited-duration recording** via segmented / fragmented-MP4 writing (stream to disk indefinitely, crash-recoverable). *This kills the "5 seconds" problem.*
- **[MUST] Start / Stop / Pause / Resume** (pause via timestamp-offset math on the shared session clock).
- **[MUST] Capture scope:** full display, a window, a specific app, and a **drag-selected area/region**.
- **[MUST] Mic + system audio** captured in sync; **[MUST] A/V sync** across screen/system-audio/mic (shared clock).
- **[MUST] Global hotkeys** (start/stop/pause) and **[SHOULD] a pre-roll countdown**.
- **[MUST] Exclude Reel's own UI** from the capture; **[MUST] don't drop frames** on long takes; **[MUST] disk/temp management + crash-safety**.
- **[SHOULD] Multi-display**, **[SHOULD] codec choice** (H.264/HEVC), **[SHOULD] live region preview**.
- **[SHOULD] Camera / webcam bubble** (PiP) — but keep it optional and simple (not talking-head production).

### 5.2 Intelligent auto-editing — the moat (ALL on-device, free, no LLM)
**Smart zoom targeting (fixes "awkward zoom"):**
- **[MUST] Zoom to the *actual clicked element*, not the raw XY.** On each click, hit-test with the **Accessibility API** (`AXUIElementCopyElementAtPosition`) to get the clicked control's exact frame + role + label. That rect (padded) is the zoom target.
- **[MUST] Layered fallback** when Accessibility is blind (web/Electron/games): **Vision** rectangle detection → **OCR** (`VNRecognizeTextRequest`) to snap to the clicked word/label → **saliency** → finally a padded box around the cursor. Graceful degradation is what makes it feel smart everywhere.
- **[MUST] Zoom amount = f(target size)** — small target ⇒ zoom harder; big/already-large target ⇒ zoom little or not at all. **Skip-zoom** when the target already fills/centers the frame.

**Motion quality (fixes "cinematic vs awkward"):**
- **[MUST] Time-domain look-ahead** — start each zoom **~300–500ms before the click lands** (the #1 pro secret; only possible because we render offline and know the future).
- **[MUST] Exact critically-damped spring** camera integrator (half-life parameterized, substepped) — never overshoots or pumps.
- **[MUST] Minimum dwell/hold + debouncing** so the camera never pumps on rapid clicks; **[MUST] segment the timeline into shots** (idle = wide, active = zoomed) instead of continuously chasing the cursor.
- **[MUST] Typing detection:** during a typing run, **hold** on the focused field — don't chase each keystroke's caret (kills seasick micro-panning).
- **[SHOULD] Scroll-following** without pumping; **[SHOULD] spatial look-ahead** (lead along cursor velocity on fast travel); **[SHOULD] quintic easing** on discrete keyframes; **[SHOULD] velocity-matched motion blur** (Screen Studio default-on).

**Cursor:**
- **[MUST] Fixed on-screen cursor size** (doesn't scale with zoom). **[SHOULD] One-Euro filter** de-jitter (speed-adaptive) or Catmull-Rom resample. **[SHOULD] Click emphasis** (ripple, pointer scale-pulse, tiny click-hold pause).

**Audio & cuts (best under-served upsell):**
- **[SHOULD] Silence / dead-air detection** via RMS energy envelope (AVFoundation + Accelerate/vDSP) and **auto-remove or auto-speed** idle gaps (using the event timeline to know when nothing's happening) via `AVMutableComposition` time-remapping.
- **[NICE] On-device speech VAD / captions** via the **Speech framework** (`SFSpeechRecognizer`, on-device) — free captions, no API.

**Structure:**
- **[NICE] Step/scene segmentation** into chapters from activity bursts; **[NICE] auto action-labels/captions per step** from Accessibility titles + OCR (e.g. "Clicked *Sign in*") — deterministic, no LLM.

### 5.3 Manual editing (for *refining* the auto-edit — not assembling from scratch)
- **[MUST] Edit zoom keyframes**: add / move / delete / retune each zoom (target, scale, duration) on the timeline + canvas.
- **[MUST] Trim** (exists) + **[SHOULD] cut segments** and **[SHOULD] speed ramps**.
- **[SHOULD] Backgrounds** (gradients/solids/images/wallpaper), padding, corner radius, shadow, aspect (exist — extend with custom + brand colors).
- **[SHOULD] Cursor controls**, **[SHOULD] click highlight/spotlight**, **[NICE] annotations / blur-redaction / text**, **[NICE] background music**.

### 5.4 Export
- **[MUST] MP4 (H.264/HEVC), MOV, GIF** with presets (resolution/fps) — exist. **[MUST] Copy-to-clipboard** (exists) — a top action for a demo tool.
- **[SHOULD] Fast, crisp, small-file exports** (VideoToolbox/Metal) — a real competitive axis, market it. **[NICE] Transparent export.**

---

## 6. How the "intelligence" is free (technical notes — feasibility-verified)

Every intelligent feature above was checked and confirmed doable **on-device, offline, no paid API, no LLM**:

| Capability | Apple framework(s) | Notes |
|---|---|---|
| What element was clicked (frame/role/label) | **Accessibility / AX** (`AXUIElementCopyElementAtPosition`) | Needs the Accessibility TCC grant; app is non-sandboxed so it's available. Primary zoom signal. |
| Find button/field when AX is blind | **Vision** `VNDetectRectanglesRequest` | On the recorded frame at click time. Web/Electron/games fallback. |
| Snap zoom to the clicked word / free captions | **Vision** `VNRecognizeTextRequest` (OCR) | On-device, no download. Also tunes zoom amount by text size. |
| No-click framing / tie-break | **Vision** saliency (`VNGenerateAttentionBasedSaliency…`) | Low-weight fallback only. |
| When to zoom / hold / pull back | **CoreGraphics** event timeline + pure math | Activity clustering → shot segmentation. |
| Smooth camera / cursor | pure math (spring, One-Euro), **Accelerate/vDSP** | No frameworks needed for the spring. |
| Silence / dead-air removal | **AVFoundation** + **Accelerate/vDSP** (RMS VAD) | Cut/speed via `AVMutableComposition`. |
| Captions / speech segments | **Speech** (`SFSpeechRecognizer`, on-device) | Optional; free. |
| (Optional) UI-element-type classifier | **Core ML / Create ML** | Only if AX+Vision fall short. Last resort. |

**The one real risk:** coordinate-space reconciliation across AX (top-left points) / Vision (bottom-left normalized) / ScreenCaptureKit (pixels) / Core Image (bottom-left). The architecture already handles this with a single documented y-flip adapter — every new detector must route through the same discipline.

---

## 7. Scope guardrails — what NOT to build (so the revamp stays focused)
- ❌ **A full multitrack/timeline editor.** The auto-edit is the pitch; manual tools are for *refining*.
- ❌ **Webcam/talking-head production, cloud collaboration, share links, a Windows port.**
- ❌ **"AI" via an LLM/API.** The intelligence is heuristics + Apple frameworks — free, private, offline. Marketing it as "AI" over-promises; market it as *auto-zoom / cursor smoothing / auto-cleanup*.
- ❌ Over-engineering the failure mode: fast/erratic input breaks any auto-zoom — **design for it** (a "calm the motion" / manual-override affordance) rather than chasing perfection.

---

## 8. What we'd want from the design revamp (deliverables)
1. A cohesive visual system across **all screens/states in §4.3** (first-run, source-select, area-select, recording bar, editor canvas/inspector/timeline, export/share, settings, trial).
2. The **recorder bar** and **area-selection overlay** (new surfaces) designed from scratch.
3. An **editor timeline** design that adds a zoom-keyframe track + audio waveform without clutter.
4. The **export/share success moment** and the **first-run permission moment** elevated to hero quality.
5. Motion/interaction notes (hover, selection, recording pulse, export beat) — this product lives or dies on how *motion* feels.

*Sources: adversarially-verified 2026 research across Screen Studio / CleanShot X / Focusee / Cursorful / Tella / CursorClip / Screen Charm and Apple framework capabilities (ScreenCaptureKit, Vision, Accessibility, AVFoundation, Speech, Accelerate). Feasibility of every on-device technique in §6 was independently verified.*
