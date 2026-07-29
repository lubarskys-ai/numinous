# Numinous

A personal app where the facets of your life — books, people, activities, trips,
journal entries — are captured as short markdown notes, wikilinked to each other
like Obsidian notes. As you write and link, a single avatar grows. **Growth comes
less from how much you log and more from how connected your life is:** linking a
book to the friend you discussed it with is worth far more than logging either
alone.

This repo currently contains **`NuminousCore`** — the data model, markdown/wikilink
parser, and the connection-weighted scoring engine. It's the concrete, testable
heart of the product brief, with the softer layers (SwiftUI app, avatar rendering,
HealthKit/Contacts/Calendar) planned on top of it.

## Status

| Layer | State |
|---|---|
| Domain model (notes, categories, axes) | ✅ built |
| Markdown + YAML frontmatter parsing | ✅ built |
| `[[wikilink]]` extraction | ✅ built |
| Connection-weighted scoring engine | ✅ built |
| Sessions, caps, delayed reveal | ✅ built |
| Growth stages / fidelity ladder | ✅ built |
| New-category → axis suggestion | ✅ built (heuristic; LLM-swappable) |
| Check suite (46 checks) | ✅ passing |
| SwiftUI app shell | ⬜ next |
| Avatar rendering | ⬜ next |
| HealthKit / Contacts / Calendar | ⬜ next |

## Build & test

The host here has only Command Line Tools (no full Xcode), and neither `XCTest`
nor `swift-testing` ships with that. So the suite runs as a plain executable:

```bash
swift build
swift run numinous-checks
```

When this moves into an Xcode project, these checks port directly to XCTest or
Swift Testing (they're written as plain assertions).

## Architecture

```
Sources/NuminousCore/
  Model/
    Axis.swift        # fixed, renamable growth axes (Body/Mind/Heart/Spirit)
    Category.swift    # unlimited user-defined categories → one axis each
    Note.swift        # a markdown note + metadata (interaction, source, session…)
  Parsing/
    WikilinkParser.swift  # [[Name]] and [[Name|alias]] extraction
    NoteParser.swift      # YAML frontmatter + body → Note
  Scoring/
    ScoringConfig.swift   # every tunable number, in one place
    ScoreEngine.swift     # the thesis: base credit + connection bonuses
    ScoreResult.swift     # per-axis totals, sessions, scored links
    Stage.swift           # revealed points → fidelity stage (public tier)
    AxisClassifier.swift  # suggest an axis for a new category
```

### The scoring engine is a pure function

`ScoreEngine.score(notes:categories:axes:)` reads the *current* state and returns
everything derivable from it. There is **no incremental persisted score**. That's
the design choice that makes the brief's requirements fall out for free:

- **Retroactive reflow** — reassign a category to a different axis and every past
  note's contribution moves with it. Nothing about journal history migrates; you
  just score again.
- **Untyped stubs** — a `[[link]]` to a not-yet-written note auto-creates an
  untyped stub. It contributes zero growth until it's given a category, so capture
  stays frictionless and categorization can happen later.

### How growth is scored

All numbers live in [`ScoringConfig`](Sources/NuminousCore/Scoring/ScoringConfig.swift)
and are meant to be tuned once it's playable. Current defaults:

| Mechanic | Value | Notes |
|---|---:|---|
| Base per manual note | 10 | credited to the note's axis |
| Base per passive (HealthKit) note | 4 | base only — never a link bonus |
| Same-axis link bonus | 5 | credited to the one axis |
| **Cross-axis link bonus** | **15** | credited to **each** of the two axes |
| In-person multiplier | ×1.5 | when either endpoint is an in-person person note |
| Session growth cap | 60 | a binge is clamped, not rewarded |
| Soft daily cap | 100 | growth beyond earns ¼ credit — diminished, never lost |

**The thesis, in numbers:** a same-axis link adds `5` to the system. A cross-axis
link adds `15` to *each* axis — `30` total. Connecting two different parts of your
life is worth **6×** logging within one part. An in-person cross-axis link is
`22.5` per axis. This is the whole point, and it's the first thing the checks
assert.

### Anti-screen-time mechanics (built into scoring, not bolted on)

- **Delayed reveal.** The most recent session's growth is *pending* — it isn't
  revealed until the next time you open the app. Removes the instant-dopamine loop
  that makes people linger after they've logged what they came to log.
- **Session cap.** No benefit to checking in repeatedly through the day; growth per
  session is capped.
- **Soft daily cap.** Consistency beats binge-logging — growth past the daily
  threshold is diminished, never clipped to zero (no punishment).
- **In-person weighting.** Real presence out-earns text/call/social contact.
- **Passive credit without opening the app.** A synced HealthKit workout gives
  baseline axis credit on its own, but the big cross-axis bonus still requires an
  actual written, linked note. Passive data removes friction; it doesn't replace
  reflection.

Note what is deliberately **absent**: no streaks, no word-count scoring (invites
padding), no "your avatar misses you," no time-away metric. Restraint is a quiet
side effect of the design, never a tracked score.

## Decisions on the brief's open questions

These were left open; here's what I picked to make it playable, all easily changed:

- **Axes: 4 — Body / Mind / Heart / Spirit.** Matches the brief's running example.
  Fully renamable and re-colorable by the user without touching scoring (the engine
  only ever reasons about axis `id`s, never names).
- **Point values / cross-axis multiplier:** the table above. Cross-axis is 3× a
  same-axis bonus *per axis* and pays two axes, so 6× in total system value.
- **Avatar fidelity:** modeled as a 6-stage ladder (Sketch → Outline → Form →
  Shaded → Defined → Realized) with continuous `fidelity` interpolation between
  stages, so the rendering layer can crossfade detail rather than snapping. Only
  the *stage* (a coarse tier) is public.
- **Platform:** kept the core as pure, dependency-free Swift (no UIKit/Foundation-UI)
  so it compiles for macOS to run these checks today and drops straight into a
  SwiftUI iOS target tomorrow.

## Worked example

The brief's sample note:

```markdown
---
category: golf
date: 2026-07-29
---
Played 18 holes with [[Sam]] today, still buzzing from finishing
[[Atomic Habits]] last week — our whole back nine turned into
talking about habit stacking. Booking [[Portugal trip]] tonight.
```

With `Sam` categorized to Heart, `Atomic Habits` to Mind, `Portugal trip` to
Spirit, and this note to Body, the engine credits: base to Body, plus three
cross-axis link bonuses (Body↔Heart, Body↔Mind, Body↔Spirit) — the reflection
that ties four areas of life together is where the growth is, not the round of
golf on its own.

## Next steps

1. **SwiftUI app shell** around `NuminousCore`: a note editor (TextKit
   `[[Name]]` highlighting), a note list, and a category→axis settings screen
   using `AxisClassifier` for the suggestion flow.
2. **Local-first storage:** notes as plain markdown files, with SQLite/Core Data
   underneath for querying the link graph.
3. **Avatar rendering:** start with a simple 2D fidelity system driven by
   `ScoreResult.stage`/`fidelity` and `axisBalance` (color cast), before wiring a
   photo-to-3D avatar API.
4. **Integrations (iOS-native):** HealthKit (passive base credit), Contacts
   (on-device `[[person]]` autocomplete), EventKit (prefill a note from a past
   calendar event) — each behind explicit per-category permission.
