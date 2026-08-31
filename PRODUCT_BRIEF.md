# REEL — PRODUCT BRIEF (the definitive "what is this" document)

> **Read this first, before any code.** This is the point of Reel, who it's for, what it must do, and what it must look and feel like. The execution order lives in `LAUNCH_PLAN.md`; the feature research lives in `REVAMP_BRIEF.md` §5–6. When any decision is ambiguous, resolve it against THIS document.
> Written 2026-08-31. Owner: Sid (Neek Labs). Price: $69 one-time (launch), $99 list.

---

## 1. THE POINT (one paragraph)

Everyone can record their screen for free — ⌘⇧5 ships with macOS. Nobody watches those recordings. A raw capture is a wall of tiny UI with a lost cursor: it looks like a bug report. What people *want* to publish is what Screen Studio popularised: the camera glides and zooms to each click, the cursor moves like silk, the footage floats on a beautiful background — a demo that looks like an ad. Today getting that means either 45 minutes of manual keyframing in a video editor, or a $29/month subscription. **Reel's point: press record, click through your app, press stop — and the edited, cinematic version already exists.** You buy it once, it runs entirely on your Mac, and nothing you record ever leaves it.

**The one-line:** *The polished demo recorder you buy once.*

## 2. WHY IT WILL SELL (positioning)

- **The demand event already happened.** In October 2025, Screen Studio — the category king — removed its $229 lifetime licence and forced subscriptions. Its users are publicly hunting one-time-purchase alternatives. Reel's job is to be the best answer they find.
- **The pitch is three promises, in this order:**
  1. **"It's already edited."** The auto-edit is the product. ~90% of buyers in this category buy for auto-zoom; cursor smoothing is #2. Everything else is table stakes.
  2. **"Buy it once."** No subscription, no account, no sign-in. The anti-subscription stance is not a pricing detail — it *is* the marketing.
  3. **"Nothing leaves your Mac."** No cloud, no uploads, no telemetry, no AI credits. All the intelligence is on-device Apple frameworks + math. Never market it as "AI" — market it as *auto-zoom, smooth cursor, auto-cleanup*.
- **Competitors:** Screen Studio ($29/mo — the giant we undercut on model), Cap (open source, rough), Canvid/CursorClip/Screen Charm ($49–79 one-time, mediocre craft). Reel wins on **execution quality of the motion**, not feature count.

## 3. WHO IT'S FOR

**The buyer is a maker who ships software and needs people to *watch* their demo:**
- Indie devs / solo founders posting launch clips and changelogs on X and Product Hunt
- SaaS teams making onboarding and feature-announcement videos
- Developer-relations / marketing people producing docs clips
- Freelancers sending "here's what I built" clips to clients over Slack

They are on a Mac, they demo **graphical, mouse-driven software**, they publish to social/docs/Slack, and their alternative is either "looks amateur" or "another subscription." They will pay $69 in one click if the sample video convinces them.

**Explicitly NOT for:** terminal/CLI demos (free tools own that), talking-head/webcam creators, teams needing cloud collaboration/share-links, Windows users. Refusing these keeps the product small and the promise sharp.

## 4. WHAT IT DOES (the experience, end to end)

### 4.1 Record — effortless
- Open Reel → pick what to capture: **a display, a window, or a dragged area** → big confident Record button (optional 3-2-1 countdown) → Reel gets out of the way (menu-bar timer, global hotkeys for pause/stop). Record as long as you want; pause and resume mid-take; a crash never loses the take.
- Reel captures three things in perfect sync: the raw video (untouched), system audio + mic, and an invisible **event timeline** — every click, move, scroll and keystroke, plus *what UI element* each click landed on.

### 4.2 The magic moment — "it's already edited"
- Stop recording → within seconds the editor opens with the demo **already produced**: camera zooming to each interaction, cursor smoothed and enlarged, click ripples, footage floating on a padded gradient card with rounded corners and a soft shadow, dead air trimmed.
- This works because Reel renders *after the fact* and knows the future: it zooms to the **element you clicked** (not the raw pixel), by an amount that fits that element's size, **arriving ~a third of a second before the click lands** — the pro-editor trick that separates cinematic from awkward. Idle moments pull wide; bursts of activity zoom in; typing holds steady on the field instead of chasing the caret. The camera never overshoots, never pumps, never gets seasick.

### 4.3 Refine — direct, never fiddly
- The auto-edit is a **draft the user owns**. Every zoom appears as a block on the timeline: drag to retime, resize for duration, click to retarget (drag the target box right on the preview), delete, or add your own. One slider calms or intensifies the whole camera. Trim with the filmstrip. Toggle silence-removal, cursor style, click effects.
- Controls exist to *refine* the auto-edit — never to assemble an edit from scratch. If a control panel starts looking like Premiere, it's wrong.

### 4.4 Ship — the payoff beat
- Export MP4 (H.264/HEVC), MOV, or GIF, with sensible presets (1080p/4K, 30/60fps) — fast, crisp, small files. Then the moment that matters: **Copy to clipboard** → paste straight into Slack, a tweet, a PR description. Success should feel like a small celebration; this is the emotion the user remembers.
- Projects reopen forever: re-edit and re-export any recording without re-recording. That's the architecture's gift — never break it.

### 4.5 Buy — honest and quiet
- Free trial = the full product with a small, tasteful "Made with Reel" chip on exports. One purchase removes it, forever, on the Macs you own. Licence entry is one field. No nagging, no countdown timers, no locked features — the watermark IS the trial mechanic.

## 5. WHAT IT LOOKS AND FEELS LIKE

**Personality:** a premium, calm, confident *creative tool* — the company it keeps is Linear, Raycast, Screen Studio, CleanShot. It must feel **crafted**, because craft is the entire pitch: a demo tool that itself looks mediocre is self-refuting. Quiet confidence, zero clutter, no gimmicks.

**Visual rules (the design system in `DesignSystem.swift` — evolve, never reinvent):**
- Committed **dark** look: deep charcoal ground (#17181C-ish) with subtle depth glows. Not theme-switchable — it's a studio.
- **One accent — violet (#7C6CF5)** — spent sparingly on primary actions and selection. Red exists only for the live-recording state. If a screen has three accented things, it has two too many.
- SF Pro, strong hierarchy: big bold moments, letter-spaced section labels, muted secondary text. 8pt grid, rounded 10–16px cards, soft shadows, generous negative space.
- **The preview is always the hero.** The user's composited demo must be the most beautiful thing on every screen; chrome stays recessed and quiet. Inspector and timeline feel like a frame around a painting.
- **Motion with intent:** hover lifts, a gentle recording pulse, an export-success beat. Micro-interactions are considered, never gratuitous — this product lives or dies on how motion feels, in the UI as much as in the output.
- **State reads at a glance:** idle vs recording vs exporting must be unmistakable across the app and menu bar.

**Feel rules:**
- Effortless > powerful. The product does 90% of the work; the UI's job is to stay out of the way and then make refining feel physical (drag the thing itself, not a number field).
- Every default is publish-ready. A user who touches nothing gets a beautiful result.
- Fast everywhere: sample renders in seconds, scrubbing is instant, export never blocks the UI.

## 6. NON-NEGOTIABLES (product constitution)

1. **Preview == export, pixel-identical**, through one shared compositor. Any feature that can't go through it doesn't ship.
2. **Two-stage architecture is sacred:** record raw + event timeline, render offline. It's what enables look-ahead, infinite re-edit, and crash safety.
3. **Local-only forever:** no accounts, no cloud, no telemetry, no LLM/API calls. Intelligence = Apple frameworks (Accessibility, Vision, AVFoundation, Speech, Accelerate) + pure math.
4. **One-time purchase forever.** Updates are free via Sparkle; if a paid "2.0" ever happens it's a new honest purchase, never a rug-pull.
5. **Scope walls:** no multitrack editor, no webcam production, no share-links, no Windows.
6. **Design for the failure mode:** erratic fast input breaks any auto-zoom — give the user a one-click "calm the motion" and manual override rather than chasing perfection.

## 7. WHAT "DONE" LOOKS LIKE

A stranger downloads Reel from the website, records a 3-minute walkthrough of their own app, touches two zoom blocks and one background swatch, exports, pastes the clip into a tweet — and it looks like they hired an editor. Total time: under six minutes. They hit ⌘E, see the watermark, and pay $69 without resenting it. That user, repeated ~120×/month, is the whole business ($500/mo kill gate → $8k+/mo success case).
