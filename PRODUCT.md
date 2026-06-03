# Product

## Register

product

## Users

Telegram users who listen to podcasts, mostly on a phone, often on the go (commute, walk, chores) and inside the Telegram app rather than a dedicated podcast client. They subscribe by RSS / Apple-search / OPML, triage an inbox of unheard episodes, and play them with resume, speed, skip, and a persistent mini-player. A meaningful subset reach for the standout capability: one-tap AI dubbing that re-voices an episode into their own language using the original speakers' voices. The job to be done is ordinary, "let me actually listen to this podcast, reliably, in the language I want," not "show me an AI demo."

## Product Purpose

Buzz-Bot is a podcast player that lives inside Telegram as a Mini App. Everyday listening is the core experience; one-tap dubbing (a cloud GPU pipeline that transcribes, translates, and re-synthesizes each speaker's voice) is a power feature layered on top, surfaced when wanted and quiet otherwise. Success is a listener who keeps their place across sessions and devices, finishes more episodes, and trusts the app enough to make it their default — including for podcasts they couldn't otherwise understand.

## Brand Personality

Calm, invisible utility. Quiet, trustworthy, and out of the way. Three words: **dependable, unobtrusive, considered**. The craft shows in details and responsiveness (instant press feedback, motion that only conveys state, never losing the user's position) rather than on the surface. Voice is plain and specific: labels say what will happen; nothing shouts. It happens to use AI; it does not look or talk like an "AI app."

## Anti-references

- **Loud "AI app" aesthetic** — gradient-soaked surfaces, decorative glassmorphism, neon, "next-gen / supercharged / seamless AI" language. The dubbing is quietly excellent, not a billboard.
- **Cluttered, ad-heavy mainstream players** — busy chrome, promos, monetized noise competing with the content.
- **Generic templated dashboard** — flat Bootstrap/Material defaults, soulless scaffolded components.
- **Over-animated / showy motion** — choreography that makes the user wait. Reliability beats spectacle.

## Design Principles

1. **Reliability is the feature.** The unglamorous things, resume-from-position, offline save/replay, autoplay, the mini-player, must be flawless. Trust is earned by never losing the user's place; that trust is the product.
2. **Disappear into the listen.** The interface serves the task and gets out of the way. Restraint by default; spend craft on details and responsiveness, not decoration.
3. **Dubbing is a power feature, not a billboard.** The AI capability is one tap away and quietly first-rate. Surface it where it helps; never make the whole app perform "AI."
4. **Native to Telegram.** Inherit the user's theme and accent, respect platform conventions, and feel like a first-class Mini App, not a transplanted web page.
5. **Motion conveys state, nothing else.** Every animation earns its place by communicating a state change, feedback, or position; quiet by default, with delight reserved for small moments.

## Accessibility & Inclusion

Target **WCAG AA**. Body text holds ≥4.5:1 contrast (large/bold text ≥3:1) — a real watch-point because colors derive from the user's Telegram theme (`--tg-theme-*`), so muted/hint text on a tinted surface must be verified, not assumed. Honor `prefers-reduced-motion` (already wired across tab bar, player controls, subtitles, and the transcript sheet): keep opacity/color cues, drop movement. Adapt to the user's Telegram light/dark theme and accent color. Touch-first: comfortable tap targets and clear pressed/active states on every control.
