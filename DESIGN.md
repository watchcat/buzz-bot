---
name: Buzz-Bot
description: A calm, theme-adaptive podcast player living inside Telegram.
colors:
  primary: "#2481cc"
  primary-ink: "#ffffff"
  ink: "#000000"
  muted: "#999999"
  bg: "#ffffff"
  surface: "#f1f1f1"
  link: "#2481cc"
  dubbed-amber: "#E78A4E"
typography:
  headline:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', sans-serif"
    fontSize: "18px"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "normal"
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', sans-serif"
    fontSize: "15px"
    fontWeight: 700
    lineHeight: 1.3
    letterSpacing: "-0.01em"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "normal"
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', sans-serif"
    fontSize: "11px"
    fontWeight: 700
    lineHeight: 1.4
    letterSpacing: "0.04em"
  mono:
    fontFamily: "ui-monospace, 'JetBrains Mono', 'SF Mono', Menlo, monospace"
    fontSize: "12px"
    fontWeight: 500
    lineHeight: 1.4
    letterSpacing: "normal"
rounded:
  sm: "7px"
  md: "10px"
  lg: "14px"
  full: "50%"
spacing:
  sm: "8px"
  md: "12px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.primary-ink}"
    rounded: "{rounded.full}"
  button-seek:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.full}"
  chip-lang:
    backgroundColor: "{colors.bg}"
    textColor: "{colors.muted}"
    rounded: "6px"
    padding: "4px 10px"
  chip-lang-active:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.primary-ink}"
    rounded: "6px"
    padding: "4px 10px"
  tab:
    backgroundColor: "transparent"
    textColor: "{colors.muted}"
    padding: "11px 12px 10px"
  tab-active:
    backgroundColor: "transparent"
    textColor: "{colors.primary}"
    padding: "11px 12px 10px"
  card:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.md}"
---

# Design System: Buzz-Bot

## 1. Overview

**Creative North Star: "The Quiet Companion"**

Buzz-Bot is a podcast player that recedes into the act of listening. It is not a destination you admire; it is a tool you trust because it never loses your place. The visual system earns that trust through restraint and through detail, not through surface decoration. Every screen is in service of one ordinary job, "let me actually listen to this, reliably, in the language I want," and the design's success is measured by how little the user has to think about it.

The system is **theme-adaptive by design**. It lives inside Telegram as a Mini App and inherits the user's own Telegram palette: the accent is their `--tg-theme-button-color`, the background and text are their chosen light or dark theme. We do not impose a brand color over the platform; we tune to it. The one deliberate exception is **Dubbed Amber** (`#E78A4E`), held fixed across every theme so "this is dubbed" always reads the same. Type is a single native system sans at a tight, fixed pixel scale, the way a competent app behaves, not a fluid editorial showpiece. Surfaces are flat, separated by tonal layering rather than shadow, with a single accent glow reserved for the primary play action.

This system explicitly rejects the loud "AI app" aesthetic (gradient-soaked surfaces, decorative glassmorphism, neon, "supercharged/seamless" language), the cluttered ad-heavy mainstream-player look, and the generic templated-dashboard feel. The product happens to use AI; it must never look like it is shouting about it.

**Key Characteristics:**
- Theme-adaptive: colors follow the user's Telegram light/dark theme and accent.
- Flat surfaces, tonal layering, one reserved accent glow.
- Single native system-sans family; tight fixed pixel scale (10–24px).
- Tactile but quiet: instant press feedback, motion only as state.
- One fixed signal color (Dubbed Amber) for AI-revoiced content.

## 2. Colors

A near-neutral, theme-driven surface carried by a single inherited accent, with one fixed amber reserved for dubbing. Values below are the **default fallbacks**; the canonical source is the matching `--tg-theme-*` variable, so the real palette is whatever the user's Telegram theme provides.

### Primary
- **Inherited Accent** (`#2481cc` default, canonical `var(--tg-theme-button-color)`): primary actions and current selection only, the play button, active tab, selected language chip, the progress fill. Never decorative. In most themes this is Telegram's blue, but it is whatever the user has set.
- **Accent Ink** (`#ffffff` default, `var(--tg-theme-button-text-color)`): text/icon on top of the accent.

### Secondary
- **Dubbed Amber** (`#E78A4E`, fixed): the one theme-independent color. Marks AI-revoiced content wherever it appears (dubbed badges, the lang-flow chip), so the signal is constant across light and dark. Used at full strength for the mark and as 13%/33% tints (`--warn-13`, `--warn-33`) for backgrounds and borders.

### Neutral
- **Ink** (`#000000` default, `var(--tg-theme-text-color)`): primary text.
- **Muted** (`#999999` default, `var(--tg-theme-hint-color)`): secondary text, inactive tab/chip labels, timestamps.
- **Background** (`#ffffff` default, `var(--tg-theme-bg-color)`): the base content surface.
- **Surface** (`#f1f1f1` default, `var(--tg-theme-secondary-bg-color)`): cards, the seek button, the tab bar, the second tonal layer.
- **Border / Overlay** (derived from ink): hairlines and pressed states are computed as low-opacity ink (`color-mix(in srgb, var(--text-color) 9% / 6% / 5%, transparent)`), so they flip correctly in dark mode instead of being hardcoded grays.

### Named Rules
**The Inherit-Don't-Impose Rule.** Color comes from the user's Telegram theme. Never hardcode a neutral gray or a brand accent where a `--tg-theme-*` variable (or an ink-derived `color-mix`) belongs; hardcoded grays break dark mode and fight the platform.

**The One Amber Rule.** `#E78A4E` means exactly one thing: dubbed/AI-revoiced content. It is the only fixed color in the system. Do not reuse it for unrelated emphasis, warnings, or decoration.

## 3. Typography

**Body Font:** native system sans (`-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', sans-serif`)
**Label/Mono Font:** `ui-monospace, 'JetBrains Mono', 'SF Mono', Menlo, monospace` (the dubbed lang-flow chip only)

**Character:** One platform-native family carries everything, headings, controls, labels, body, so the app feels like part of Telegram rather than a transplanted web page. Hierarchy comes from size and weight, not from a second typeface. The lone monospace is a deliberate accent on the language-flow chip (e.g. `EN → ES`), where fixed-width digits and arrows read as "machine output."

### Hierarchy
- **Headline** (700, 18px, 1.2): screen titles, e.g. "Inbox".
- **Title** (700, 15px, -0.01em): player episode titles and the active karaoke subtitle line.
- **Body** (400, 14px, 1.5): episode descriptions, list content, default text. Prose caps at 65–75ch.
- **Label** (700, 11px, 0.04em): chips, small controls, the speed/CC toggles. Short labels only.
- **Mono** (500, 12px): the dubbed lang-flow chip exclusively.

### Named Rules
**The One-Family Rule.** No display typeface. A single native sans in two or three weights carries the whole UI; reaching for a second family is indecision, not richness.

**The Fixed-Scale Rule.** Sizes are fixed px (10–24), never `clamp()`/fluid. Users view at a consistent phone DPI; a heading that shrinks in a panel looks worse, not designed.

## 4. Elevation

Flat by default. Depth is conveyed almost entirely through **tonal layering**, the content background, a slightly different `--secondary-bg` surface for cards/toolbars/the tab bar, and ink-derived borders and overlays, never through a shadow stack. The single intentional shadow in the system is the glow beneath the primary play button, which exists to make the one action you reach for most feel lifted and alive.

### Shadow Vocabulary
- **Accent Glow** (`box-shadow: 0 4px 20px color-mix(in srgb, var(--button-color) 45%, transparent)`): the large play/pause button only. On press it tightens (`0 2px 10px ... 30%`) in concert with `scale(0.90)`.

### Named Rules
**The Flat-By-Default Rule.** Surfaces are flat and separated by tone. The only shadow in the product is the play button's accent glow; do not add card shadows, drop shadows, or elevation ramps to make things "pop."

## 5. Components

Components are tactile but quiet: a satisfying, instant press response, then stillness. Motion conveys state and nothing else.

### Buttons
- **Shape:** circular for media transport (`50%`), pill/rounded for toggles and chips (6–7px).
- **Primary (play/pause):** inherited accent background, accent-ink glyph, circular, with the Accent Glow. Press: `transform: scale(0.90)` over 120ms on `--ease-out`, glow tightens.
- **Seek (±30s):** `--overlay` background, ink glyph, circular 48px, two-line icon+label. Press: `scale(0.90)`, background deepens.
- **Toggles (speed / CC):** ghost pill at rest (muted text, hairline border); active state fills with `--accent-tint` background + accent text/border. Press: slight opacity drop.
- **Icon buttons:** transparent at rest, `--overlay` on press; a `--spinning` variant rotates at `0.7s linear` for refresh.

### Chips
- **Language chips** (`sub-lang-chip` / `dub-lang-chip`): small pills (6px radius, 4×10px padding), hairline border, muted label at rest. **Selected** fills with the inherited accent + accent ink, easing color/background/border over 150ms. **Pending** pulses opacity (dubbing in progress); **failed** uses a red border; **add** uses a dashed border.
- **Lang-flow chip:** monospace, renders the dub direction (`EN → ES`) in Dubbed Amber context.

### Cards / Containers
- **Corner Style:** `--radius` (10px); small elements `--radius-sm` (7px), sheets `--radius-lg` (14px).
- **Background:** `--card-bg` (= `--secondary-bg`), the second tonal layer.
- **Shadow Strategy:** none, per the Flat-By-Default Rule; separation is tonal + hairline border (`--border`).
- **Internal Padding:** `--gap` (12px) baseline.

### Navigation
- **Bottom tab bar (signature):** an **expanding-pill** nav. Inactive tabs show icon only (`flex: 0 1 auto`); the active tab grows (`flex: 1 1 auto`) and reveals its label via an animated `max-width` on `--ease-out`, with an accent-colored bottom border. Never wraps. Press gives `scale(0.97)` feedback. Reduced-motion drops the width animation and keeps the color cue.

### Karaoke Subtitle Panel (signature)
A centered stack of cue lines at 28% opacity; the current line lifts to full opacity and `transform: scale(1.15)` (GPU-composited, never animating `font-size`) over 300ms. Language chips switch the rendered text; a transcript sheet slides up (`translateY(100%)`, custom ease) and back down on exit.

### Dub Progress (signature)
A 3px tonal track with an accent fill that grows via `transform: scaleX()` (origin-left, GPU), shimmering opacity while in flight. Theme accent, never amber, for the bar itself.

## 6. Do's and Don'ts

### Do:
- **Do** drive color from `--tg-theme-*` variables and ink-derived `color-mix()`. The app must follow the user's Telegram light/dark theme and accent.
- **Do** keep `#E78A4E` (Dubbed Amber) exclusively for AI-revoiced content, the one fixed signal in the system.
- **Do** keep surfaces flat; separate with tone and hairline borders. Reserve the single accent glow for the play button.
- **Do** give every control an instant pressed state (`scale(0.90)` transport, `scale(0.97)` tabs, opacity for chips) on `--ease-out`.
- **Do** verify muted/hint text hits ≥4.5:1 against its surface in both light and dark; the tinted, theme-derived backgrounds make low-contrast gray text a real risk.
- **Do** animate `transform`/`opacity` only; gate every animation behind `prefers-reduced-motion`.

### Don't:
- **Don't** ship the loud "AI app" aesthetic: no gradient-soaked surfaces, no decorative glassmorphism, no neon, no "supercharged/seamless/next-gen" language. The product uses AI; it must not look like it.
- **Don't** drift toward a cluttered, ad-heavy mainstream-player look or a generic templated dashboard.
- **Don't** hardcode neutral grays or a fixed brand accent where a theme variable belongs; it breaks dark mode.
- **Don't** add card shadows or an elevation ramp. Flat-by-default; the play glow is the only shadow.
- **Don't** animate layout properties (`font-size`, `width`, `margin`) for motion; use `transform`/`opacity` (e.g. the subtitle `scale`, the progress `scaleX`).
- **Don't** introduce a second type family or fluid `clamp()` headings.
