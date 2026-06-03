# Dubbed Page + Language Filter — Design Spec

**Date:** 2026-06-03
**Status:** Approved (pending spec review)

## Goal

Turn the inbox "Latest dubbed" bar's **See all** link into a real destination: a
dedicated page listing all of the user's dubbed episodes, with a **persistent,
server-side language filter**. Selecting languages (e.g. EN + RU) restricts both
the Dubbed page list *and* the inbox bar to those languages.

## User-facing behaviour

- Tapping **See all** on the inbox dubbed bar opens a new **Dubbed** page.
- The page shows every done dub for the user as a vertical list (most recent first).
- A language chip row at the top lets the user toggle which target languages are
  shown (multi-select). Selecting EN + RU shows only EN and RU dubs.
- The selection is a **saved preference** (localStorage): it persists across app
  restarts and applies to the inbox bar too — the bar silently shows only dubs in
  the selected languages, with no extra control in its header.
- Empty selection = **all languages** (filter off).

## Decisions (locked)

| Decision | Choice |
|---|---|
| Filter persistence | Saved to localStorage, global, applies to page + inbox bar |
| Filtering location | **Server-side**, via a `langs` query param on both endpoints |
| List layout | Vertical `episode-item`-style rows with an amber `EN→RU` chip |
| Chip selected colour | Accent (`--button-color`), like subtitle-language chips. Amber stays reserved for the dubbed-content `EN→RU` marker (One-Amber rule) |
| Chip labels | Language codes uppercased (`EN`, `RU`) — matches existing langflow chips |
| Entry point | `See all` → pushed `:dubbed` sub-view (back → Inbox). Not a tab |
| Empty `langs` | All languages (no filter) |

## Architecture

### Backend (Crystal)

Two endpoints gain an optional `langs` param (comma-separated lowercase codes);
absent/empty = no language filter.

**`GET /inbox/dubbed?limit=12&langs=en,ru`** (existing route, extended)
- Returns `{items: [...]}` — the recent dubbed list for the inbox bar, now
  filtered to `langs` *before* the limit (filter-then-limit), so a selected
  language always surfaces its latest dub in the bar.

**`GET /dubbed?limit=100&langs=en,ru`** (new route)
- Returns `{items: [...], languages: [...]}`.
- `items`: full dubbed history (filtered by `langs`), ordered `completed_at DESC`,
  limit clamp `1..200` (default 100).
- `languages`: the **unfiltered** distinct set of target languages the user has
  done dubs in, sorted. Drives the chip row, so chips stay stable regardless of
  the current selection.

**Model (`src/models/dubbed_episode.cr`)**
- `recent_for_inbox(user_id, limit, langs : Array(String)? = nil)` — add optional
  `langs` filter to the existing query (`AND de.language = ANY($n)` when present).
- `all_for_user(user_id, limit, langs : Array(String)? = nil) : Array(DubbedRecent)`
  — new; same `DubbedRecent` shape and JOINs as `recent_for_inbox`, ordered
  `de.completed_at DESC NULLS LAST` (recency, no subscribed-first bias).
- `distinct_languages_for_user(user_id) : Array(String)` — new; `SELECT DISTINCT
  de.language ... WHERE de.status = 'done' ORDER BY de.language`.

Parsing `langs`: split on `,`, strip, downcase, reject blanks; `nil` if empty.

### Frontend (ClojureScript / re-frame)

**State**
- `[:dubbed-filter :langs]` — a set of selected codes, e.g. `#{"en" "ru"}`.
  Loaded in `db.cljs` from localStorage `buzz-dubbed-langs` (guarded with
  `(exists? js/localStorage)`, comma-split into a set; empty string → `#{}`).
- `[:dubbed :items]`, `[:dubbed :languages]`, `[:dubbed :loading?]`,
  `[:dubbed :loaded?]` — the page's data.
- `[:inbox-dubbed …]` — unchanged shape; items are now already language-filtered
  by the server, so the bar needs no client-side filtering.

**Query-string helper** (`events.cljs`)
- `(dubbed-langs-qs db sep)` → `""` when no langs, else `"<sep>langs=en,ru"`
  (sorted, comma-joined). `sep` is `?` or `&` depending on the URL.

**Events**
- `dubbed-fetch` (existing helper): append `(dubbed-langs-qs db "?")` to
  `"/inbox/dubbed"` so the bar fetch carries the current filter.
- `::fetch-dubbed [force?]` — GET `"/dubbed?limit=100" + (dubbed-langs-qs db "&")`;
  `:loaded?`-guarded like `dubbed-fetch`; `:on-ok [::dubbed-loaded]`,
  `:on-err [::dubbed-err]`.
- `::dubbed-loaded` — store `:items` (vec), `:languages` (vec), set
  `:loaded? true`, `:loading? false`.
- `::dubbed-err` — silent; `:loading? false`, `:loaded? true` (mirrors
  `::inbox-dubbed-err`).
- `::toggle-dubbed-lang [lang]` — toggle `lang` in `[:dubbed-filter :langs]`,
  persist to localStorage, then refetch both surfaces:
  `:dispatch-n [[::fetch-dubbed true] [::fetch-inbox-dubbed true]]`.
- `::clear-dubbed-langs` — reset to `#{}`, persist, same refetch.
- `::navigate` (existing): add `:dubbed [::fetch-dubbed]` to the `fetch-event`
  `case`, so navigating to the page loads it.

**Subscriptions** (`subs.cljs`)
- `::dubbed-items` → `[:dubbed :items]`
- `::dubbed-languages` → `[:dubbed :languages]` (chip set)
- `::dubbed-selected-langs` → `[:dubbed-filter :langs]` (default `#{}`)
- `::dubbed-loading?` → `[:dubbed :loading?]`
- `::inbox-dubbed-items` — unchanged (raw items; server already filtered).

**View** (`src/cljs/buzz_bot/views/dubbed.cljs`, new)
- `.section-header` with a back button (`← Dubbed`) dispatching `[::navigate :inbox]`.
- Language chip row: for each lang in `::dubbed-languages`, a toggle chip
  (`role="button"`, `tab-index 0`, `aria-pressed`, Enter/Space) →
  `[::toggle-dubbed-lang lang]`. Selected = filled accent. When
  `::dubbed-selected-langs` is non-empty, an "All" reset chip → `[::clear-dubbed-langs]`.
- List: vertical rows (reuse `episode-item` structure) — cover thumb, feed name,
  title, meta line = amber `EN→RU` (via `inbox-dubbed/fmt-langflow`) + duration +
  `fmt-relative-time`, ▶ icon. Row click → `[::navigate :player {:episode-id …
  :from "dubbed" :dub-lang target_lang}]`. Keyboard + aria per the a11y standard
  (role=button, tab-index, aria-label, Enter/Space).
- Empty states (reuse the `.empty-state` component):
  - loading → `.loading`.
  - `::dubbed-languages` empty → "No dubbed episodes yet" + body explaining dubs
    appear here once an episode is dubbed.
  - items empty but a filter is active → "No dubs in the selected languages" +
    **Show all languages** → `[::clear-dubbed-langs]`.

**Routing / wiring**
- `layout.cljs`: add `:dubbed [dubbed/view]` to the `case view`.
- `inbox_dubbed.cljs`: "See all" button → `[::navigate :dubbed]` (was
  `::see-all-dubbed-stub`).
- `events.cljs`: retire `::see-all-dubbed-stub` (no longer referenced).
- `player.cljs`: back button already routes via `:from`; add `"dubbed"` to the
  set of recognised back origins so player → back returns to the Dubbed page.

**CSS** (`public/css/app.css`)
- `.lang-filter` chip row (horizontal, wraps), reusing the existing chip visual
  vocabulary; selected chip fills `--button-color` with `--button-text-color`.
- Reuse `.episode-item`, `.episode-thumb`, `.episode-info`, `.episode-feed-name`,
  `.episode-title`, `.episode-play-icon`. Row meta uses the existing
  `--warn-text` amber for the `EN→RU` pair (mono).

## Testing

- **Crystal:** the model methods are SQL; verify by hand against Neon (per the
  project's DB-test convention). Add a route smoke check if the suite supports it.
- **cljs node-tests:** pure helpers are unit-testable —
  - `dubbed-langs-qs` (empty set → `""`; `#{"ru" "en"}` → `"?langs=en,ru"` sorted).
  - `::toggle-dubbed-lang` reducer (add/remove, persistence call mocked).
  Keep DOM/SDK out of the tested namespaces (load-safe under node, per the
  existing `(exists? …)` guards).

## Out of scope (YAGNI)

- Pagination / infinite scroll (single capped fetch of 200 is plenty for now).
- A 5th bottom-nav tab for Dubbed (the See-all entry is the ask; revisit later).
- Server-synced (cross-device) filter preference — localStorage is sufficient.
- Language *names* (English/Russian) — codes match the existing chip vocabulary.
