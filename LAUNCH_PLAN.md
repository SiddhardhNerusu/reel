# REEL — LAUNCH PLAN (v1.0, 2026-08-31)

> **For:** Opus 5 execution, session by session. Self-contained: read this + REVAMP_BRIEF.md §5–§7 and you can build without guessing.
> **Goal:** a **paid, notarized, purchasable** Reel at **$69 one-time** (launch price; list $99) in front of strangers ASAP.
> **Why now:** Screen Studio removed lifetime pricing Oct 2025 → live one-time-purchase refugee wave. Window 6–12 months, closing (Cap OSS, Canvid lifetime).
> **KILL GATE:** $500/mo within 3 months of launch, or stop.
> **Prime directive:** every phase below is ordered by *distance to a sellable product*, not by fun. Polish that doesn't block a stranger's purchase goes AFTER the buy button exists.

---

## 0. VERIFIED CURRENT STATE (audited live 2026-08-31 — build green, app driven by hand)

**Works, verified by eye today:**
- Full Stage-2 pipeline: sample → solve → compose → export MP4 in ~5s. Preview == export.
- Editor: framed aspect-correct preview, 5 background swatches, 5 aspect chips, auto-zoom toggle, filmstrip trim timeline w/ handles + playhead + scrub, play/pause (Space), MP4/GIF export, copy-to-clipboard toast, ⌘E/Esc/←→ shortcuts.
- **Auto-zoom verified live**: mid-playback the camera visibly zooms onto the clicked button; Sunset+1:1 re-composite is instant.
- Launcher: hero, source segmented picker (display), permission card, sample path, recording pill (elapsed/pause/stop), post-record cards.
- Design system (RC tokens, dark charcoal + violet), app icon in asset catalog.

**In code, compile-verified but NEVER runtime-validated (no Screen Recording grant on any current signature):**
- Real recording: start / stop / pause-resume (PTS retiming), unlimited duration (movieFragmentInterval=2s), system audio + mic inputs wired (`ScreenRecorder.swift:107,131-145`), own-window exclusion, crash-safe fragments.
- AX element resolution per click (`Events/ElementResolver.swift`) → `InputEvent.targetRect` → size-aware zoom w/ skip-when-large (`CameraPathSolver`).
- Silence/idle cuts on export (`AudioSilence` + `IdleCutPlanner`, `EditorModel.swift:169`).

**Missing / stubbed (confirmed today):**
- Window capture UI says "arrives in a later build" (`ContentView.swift:105`) — `ShareableContent.filter(forWindow:)` exists, unwired.
- No area/region selection. No global hotkeys, no countdown, no menu-bar presence, no Settings window.
- Export: H.264 + GIF only. No MOV/HEVC, no resolution/fps presets.
- No zoom-keyframe editing (the #1 pro feature gap). No cursor controls in inspector. No custom background (color/image). No undo/redo. No project reopen/recents (a .reelproj exists on disk but the app can't reopen one after relaunch).
- **Zero commercial infrastructure:** no licensing, no trial, no watermark, no Sparkle, no Developer ID/notarization, no website.
- **NO GIT REPO.**

**Bugs found in today's hands-on session (fix in P2):**
1. Launcher's "Exported" toast bleeds through/under the editor sheet (z-order) — visible in every editor screenshot.
2. Export/result card clips against the window's bottom edge on the launcher.
3. Aspect chips wrap awkwardly (9:16 alone on row 2) — FlowLayout spacing.
4. Editor is a sheet over the launcher (traffic lights ambiguity); should be its own scene/window or fully replace content.
5. Title is static "Untitled demo" — no rename.

**Known macOS-26-SDK API drifts (memory, apply when touched):** `CGEvent.tapEnable(tap:enable:)`; `AVMutableVideoComposition.videoComposition(with:applyingCIFiltersWithHandler:)` is async-throws factory; `AVAssetImageGenerator.image(at:)` async.

---

## OWNER TASKS (Sid — cannot be done by Claude; each blocks the phase named)
- **OT-1 (blocks P0):** approve `git init` + first commit + private GitHub push. (Claude never commits without approval — standing rule.)
- **OT-2 (blocks P0):** grant **Screen Recording** + **Accessibility** to the dev-cert-signed Reel build in System Settings (Touch ID required). App must be re-signed w/ cert hash 850BD1… (team KX4SBPJ7C4) for the grant to stick — re-sign step is scripted in P0.
- **OT-3 (blocks P4):** Apple Developer Program: create a **Developer ID Application** certificate (none exists — only Apple Development). Needed for notarization.
- **OT-4 (blocks P4):** create Lemon Squeezy (or Paddle) account + product. Claude wires the SDK; Sid owns the account/payout.
- **OT-5 (blocks P5):** buy domain (suggest reel.app-style .com/.app), point DNS.

---

## PHASE 0 — Foundation + first real recording (1 session)
*Nothing else matters until a real recording has round-tripped on this Mac.*

- P0.1 **Git**: `git init`, commit everything (gitignore already excludes build/ + samples), push private. [after OT-1]
- P0.2 **Stable signing**: script `scripts/sign_dev.sh` — build, then `codesign --force --deep --sign 850BD1… Reel.app`; document in README. TCC identity must stop churning.
- P0.3 **Runtime smoke (after OT-2)**: record 60–90s of real Safari/Finder usage w/ clicks, typing, scrolling, a pause/resume mid-take. Verify: fragments on disk, stop() no-hang, doc built, pausedIntervals excised, editor opens it, export plays, A/V sync, AX targetRects present, zoom frames the clicked elements.
- P0.4 **Fix everything P0.3 surfaces.** Expect writer-lifecycle and AX-threading bugs; the July adversarial review fixed the *predictable* ones, runtime will find the rest. Budget most of the session here.
- P0.5 Record the **hero demo of Reel itself** using Reel (dogfood artifact for P5's landing page).

**Acceptance:** a stranger-grade real recording exported and watched, from this exact codebase.

## PHASE 1 — Recording completeness (1–2 sessions)
*A recorder that only captures full displays isn't sellable against free ⌘⇧5.*

- P1.1 **[MUST] Window capture**: wire `filter(forWindow:)`; window picker UI w/ live thumbnails (`SCScreenshotManager`); handle window-moved/resized (10Hz window.json already planned in BUILD_PLAN §window).
- P1.2 **[MUST] Area selection**: full-screen dimmed overlay (borderless NSWindow, level .screenSaver), drag rect, dim outside, Enter/Esc; record cropped via `sourceRect` on SCContentFilter/config. Design per REVAMP_BRIEF A3.
- P1.3 **[MUST] Global hotkeys**: start/stop (⌥⌘R default), pause — Carbon RegisterEventHotKey or MASShortcut-style local impl (no new deps; ~120 LOC).
- P1.4 **[MUST] Countdown** (3-2-1 overlay, skippable, off-switch) + **menu-bar item** during recording (elapsed, pause/stop) so the pill never has to sit inside the capture.
- P1.5 **[SHOULD] Mic toggle + input picker** on launcher (capture already wired; UI missing). Default: system audio ON, mic ON if granted.
- P1.6 **[SHOULD] App-scope capture** (all windows of one app). **[NICE] Multi-display polish.**

**Acceptance:** record display / window / area, hands-off via hotkeys, without Reel's UI in frame.

## PHASE 2 — Editor to "pro" (2 sessions)
*This is the "make it more professional and intuitive" core. Order matters.*

- P2.1 **[MUST] Zoom-keyframe track** on the timeline: each solved zoom = an editable block (drag=retime, resize=duration, select→inspector shows target/scale, delete, add-at-playhead). Solver becomes *suggestions the user owns* (`CameraOverride.swift` model exists, unused — wire it). This single feature moves Reel from toy to tool.
- P2.2 **[MUST] Canvas direct-manipulation**: with a zoom block selected, show its target rect on the preview; drag/resize to retarget (B4 in brief).
- P2.3 **[MUST] Inspector expansion** (grouped, collapsible): Motion (zoom intensity slider = maps to SolverConfig zoomMax/lead; "calm motion" preset), Cursor (size, smoothing on/off, click ripple on/off), Frame (padding, corner radius, shadow), Background (5 presets + custom color picker + image), Audio (silence-removal toggle **with preview parity** — cuts currently export-only; either preview them via TimeRemap in PreviewComposition or label "applied on export").
- P2.4 **[MUST] Undo/redo** (UndoManager on EditorModel mutations) + **rename title** + **project persistence**: recents list on launcher, reopen .reelproj after relaunch.
- P2.5 **[MUST] Bug fixes** from §0: toast z-order, result-card clipping, chip wrap, editor-as-window, plus a pass on every ⚠️ in REVAMP_BRIEF §4.3.
- P2.6 **[SHOULD] Export presets**: resolution (1x/2x/720/1080/4K-cap), fps (30/60), MOV + HEVC codec option, GIF quality/width; remember last. **[SHOULD] audio waveform lane** under filmstrip.
- P2.7 **[NICE] Cut segments + speed ramps. [NICE] Captions (on-device Speech).** Defer both past launch if timeline pressure.

**Acceptance:** a skeptical buyer can retune any awkward zoom in <10s; nothing in daily flow feels stubbed.

## PHASE 3 — Commercial skeleton (1 session)
- P3.1 **[MUST] Trial + licensing**: free trial = full features, **watermark on export** (small "Made with Reel" corner chip, tasteful); license key removes it. Lemon Squeezy license API (activate/validate offline-grace) behind a `Licensing` protocol so the MoR is swappable. Buy button opens checkout URL. [needs OT-4]
- P3.2 **[MUST] Settings window**: hotkeys, countdown on/off+length, default background/aspect, export defaults, mic default, license tab (key entry, status, deactivate).
- P3.3 **[MUST] Sparkle 2** (the one allowed dependency) + appcast hosted on the website repo; signed updates.
- P3.4 **[SHOULD] First-run tour** (3 quiet cards max) + sample auto-render on first launch so the first thing a user ever sees is the magic.

## PHASE 4 — Ship infrastructure (1 session) [needs OT-3]
- P4.1 Release config: hardened runtime ON, Developer ID signing, `notarytool` submit+staple, DMG (create-dmg style script, no deps), `scripts/release.sh` end-to-end (build→sign→notarize→staple→dmg→appcast).
- P4.2 QA matrix on this Mac: fresh-user run (new macOS account), 10-min recording, pause-heavy take, area+window takes, GIF>50MB guard, export-while-playing, no-mic-permission path, license activate/deactivate.
- P4.3 Crash safety: verify fragment recovery ("Reel quit during a recording — recover?" path) — the writer leaves playable fragments; add the recovery UI.

## PHASE 5 — Launch (with Sid, 1 session) [needs OT-5]
- P5.1 One-page site: hero video (P0.5, made with Reel), the three motions (zoom/cursor/background) shown not told, "$69 · yours forever · nothing leaves your Mac", FAQ (vs Screen Studio subscription, privacy, refunds), download.
- P5.2 Launch posts: X thread (build-in-public angle + the anti-subscription hook), Product Hunt, HN Show HN (honest indie framing), r/macapps. Reply-all day-of.
- P5.3 Instrument the kill gate: LS sales dashboard + a weekly revenue note. **$500/mo by launch+90d or stop.**

---

## GUARDRAILS (unchanged from REVAMP_BRIEF §7 — enforce in every session)
- ❌ No multitrack editor, no webcam production, no cloud/accounts/share-links, no Windows, no LLM/API calls, no telemetry.
- ❌ No new dependencies except Sparkle (P3.3). Everything else is Apple frameworks + pure math.
- ✅ Preview==export through the ONE compositor function — every new visual feature goes through it or doesn't ship.
- ✅ One y-flip adapter for all coordinate spaces — new detectors route through it.
- ✅ Design tokens only (DesignSystem.swift); evolve, don't reinvent. The preview is the hero; chrome stays quiet.
- ✅ Build green + tests green (SP-10 22, Render 5) at the end of every session; add tests for new pure math (keyframe editing ops, area-rect math).

## SESSION MAP (realistic: ~6–8 working sessions to launch-ready)
P0 → P1 → P1/P2 → P2 → P2/P3 → P3/P4 → P4 QA → P5 launch.
If a session must be cut short, cut from the CURRENT phase's SHOULDs — never reorder phases. Features beyond P2.7 (captions, scenes, speed ramps, motion blur) are **post-revenue**: they ship in updates, which is exactly what Sparkle is for and gives launch buyers visible momentum.
