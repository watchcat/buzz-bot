# Per-feed delivery mode — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-feed `off | notify | mp3` delivery setting that the user controls from the Feed-detail screen, with server-side fanout that posts Telegram cards or audio uploads when new episodes arrive.

**Architecture:** New `user_feeds.delivery_mode` + `user_feeds.last_viewed_at` columns. `FeedRefresher` calls a new `Delivery::Dispatch.fanout(feed, inserted_episodes)` after each refresh, which fans subscribers into per-(user, episode) `spawn`ed fibers. `notify` mode uses a new `Delivery::Notify` formatter that calls `send_photo` (with text-only fallback); `mp3` mode reuses the existing `AudioSender.send_to_user`. The Mini App gets a redesigned single-row header on the per-feed page with a delivery chip (tap cycles, long-press opens `Telegram.WebApp.showPopup`), a sort chip, a `⋯` overflow menu, and a `NEW` badge on unseen episodes.

**Tech Stack:** Crystal/Kemal + crystal-pg + Tourmaline · ClojureScript + Reagent + re-frame + shadow-cljs (`:node-test`) · Plain CSS via Telegram theme custom properties.

**Spec:** `docs/superpowers/specs/2026-05-28-feed-delivery-mode-design.md`.

**Reference assets:** `/Users/watchcat/Downloads/design_handoff_feed_delivery/` — `feed-v3.jsx`, `feed-chrome.jsx`, `screenshots/state-{off,notify,mp3}.png`. Icon SVGs (`BellIcon`, `BellOffIcon`, `MP3Icon`) live in `feed-chrome.jsx` lines 168–203.

**Verification commands used throughout:**

| Job | Command |
|---|---|
| Crystal type-check | `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'` |
| Crystal specs | `nix-shell -p crystal -p shards --run 'crystal spec'` |
| CLJS unit tests | `nix-shell -p jdk21_headless --run 'npm test'` |
| CLJS release build | `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs release app'` |
| Apply migration | `psql "$(kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get secret buzz-bot-env -o jsonpath='{.data.DATABASE_URL}' \| base64 -d \| sed -E 's#\?.*#?sslmode=require#')" -f migrations/019_feed_delivery_mode.sql` |

---

## File map

**Create:**

| Path | Responsibility |
|---|---|
| `migrations/019_feed_delivery_mode.sql` | Adds `delivery_mode`, `last_viewed_at` columns + check constraint + partial index. |
| `src/models/user_feed.cr` | Lookup/write helpers for `user_feeds.delivery_mode` and `last_viewed_at` + `delivery_subscribers_for(feed_id)` query that backs the fanout. |
| `src/delivery/dispatch.cr` | `Delivery::Dispatch.fanout` entry; pure `eligible_targets` filter; data records (`Subscriber`, `EpisodeRef`, `Target`). |
| `src/delivery/notify.cr` | `Delivery::Notify.send(telegram_id, feed, episode)` — builds caption + Mini-App-button reply markup + calls `send_photo` (text fallback if no cover). |
| `spec/delivery/dispatch_spec.cr` | Pure-fn tests for `Delivery::Dispatch.eligible_targets`. |
| `spec/delivery/notify_spec.cr` | Pure-fn tests for `Delivery::Notify.build_caption`. |
| `src/cljs/buzz_bot/delivery.cljs` | Pure CLJS helpers — `next-mode`, `mode->label`, `mode->icon-key`, `new?` predicate. |
| `test/buzz_bot/delivery_test.cljs` | cljs.test deftests for the above. |
| `src/cljs/buzz_bot/views/delivery_chip.cljs` | Delivery chip Reagent component (form-2 with long-press timer). |

**Modify:**

| Path | Why |
|---|---|
| `src/models/episode.cr` | `upsert` returns `UpsertResult{episode, was_inserted}` via `(xmax = 0)` RETURNING. |
| `src/feed_refresher.cr` | Use new return value to compute `inserted_eps`; call `Delivery::Dispatch.fanout`. |
| `src/web/routes/feeds.cr` | New `PATCH /feeds/:id/delivery_mode` + `POST /feeds/:id/viewed` routes. |
| `src/web/routes/episodes.cr` | Extend `GET /episodes` response with `delivery_mode` and `new_episode_ids`. |
| `src/cljs/buzz_bot/db.cljs` | Extend `:episodes` slice with `:delivery-mode`, `:new-episode-ids`, `:delivery-pending`. |
| `src/cljs/buzz_bot/events.cljs` | New events: `::cycle-delivery-mode`, `::set-delivery-mode`, `::delivery-patch-ok`, `::delivery-patch-err`, `::mark-feed-viewed`. Extend `::episodes-loaded` handler. |
| `src/cljs/buzz_bot/subs.cljs` | New subs: `::delivery-mode`, `::new-episode-ids`. |
| `src/cljs/buzz_bot/views/episodes.cljs` | Header collapses to one row + chips row + `NEW` badge + mount-time mark-viewed. |
| `public/css/app.css` | New `--accent-13`/`--accent-33` vars; `.delivery-chip`, `.sort-chip`, `.episode-new-badge`, `.overflow-menu` rules. |

---

## Task 1 — Schema migration

**Files:**
- Create: `migrations/019_feed_delivery_mode.sql`

- [ ] **Step 1: Write the migration file**

```sql
-- 019_feed_delivery_mode.sql
-- Per-feed delivery mode + last-viewed timestamp on user_feeds.
-- Joins the existing episode_order column already on the same table.

ALTER TABLE user_feeds
  ADD COLUMN delivery_mode  VARCHAR(8)  NOT NULL DEFAULT 'off',
  ADD COLUMN last_viewed_at TIMESTAMPTZ;

ALTER TABLE user_feeds
  ADD CONSTRAINT user_feeds_delivery_mode_chk
  CHECK (delivery_mode IN ('off', 'notify', 'mp3'));

-- Partial index for the fanout lookup:
--   "who wants Telegram delivery for this feed?"
-- Off-mode subscribers (the majority) are skipped by the WHERE clause.
CREATE INDEX user_feeds_by_feed_delivery
  ON user_feeds (feed_id, delivery_mode)
  WHERE delivery_mode <> 'off';
```

- [ ] **Step 2: Apply the migration against Neon**

Run:
```
psql "$(kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get secret buzz-bot-env -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')" -f migrations/019_feed_delivery_mode.sql
```
Expected: three `ALTER TABLE` / `CREATE INDEX` notices, no errors.

- [ ] **Step 3: Verify the schema change**

Run:
```
psql "$(kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get secret buzz-bot-env -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')" -c "\d user_feeds"
```
Expected output includes:
```
 delivery_mode  | character varying(8)     |           | not null | 'off'::character varying
 last_viewed_at | timestamp with time zone |           |          |
```
And:
```
"user_feeds_by_feed_delivery" btree (feed_id, delivery_mode) WHERE delivery_mode::text <> 'off'::text
Check constraints:
    "user_feeds_delivery_mode_chk" CHECK (delivery_mode::text = ANY (ARRAY['off'::character varying, 'notify'::character varying, 'mp3'::character varying]::text[]))
```

- [ ] **Step 4: Commit**

```
git add migrations/019_feed_delivery_mode.sql
git commit -m "db: add user_feeds.delivery_mode + last_viewed_at (019)"
```

---

## Task 2 — UserFeed model

Centralize `user_feeds` lookups (today scattered inline across routes). The new model holds delivery-mode read/write and last-viewed bumping; future per-user-feed state lives here too.

**Files:**
- Create: `src/models/user_feed.cr`

- [ ] **Step 1: Create the model file**

```crystal
require "json"
require "../db"

# UserFeed — per-user, per-feed state stored in the `user_feeds` table.
# (The Feed model owns feed-level data; user_feeds joins users ↔ feeds with
# per-relationship settings like episode_order, delivery_mode, last_viewed_at.)
struct UserFeed
  VALID_DELIVERY_MODES = %w[off notify mp3]

  # Subscriber projection used by the delivery fanout. Carries everything
  # needed to build a delivery target without re-querying.
  record Subscriber,
    user_id       : Int64,
    telegram_id   : Int64,
    mode          : String,
    subscribed_at : Time

  def self.set_delivery_mode(user_id : Int64, feed_id : Int64, mode : String) : Bool
    raise ArgumentError.new("invalid delivery mode: #{mode}") unless VALID_DELIVERY_MODES.includes?(mode)
    result = AppDB.pool.exec(
      "UPDATE user_feeds SET delivery_mode = $3 WHERE user_id = $1 AND feed_id = $2",
      user_id, feed_id, mode
    )
    result.rows_affected > 0
  end

  def self.get_delivery_mode(user_id : Int64, feed_id : Int64) : String
    AppDB.pool.query_one?(
      "SELECT delivery_mode FROM user_feeds WHERE user_id = $1 AND feed_id = $2",
      user_id, feed_id, as: String
    ) || "off"
  end

  def self.touch_viewed(user_id : Int64, feed_id : Int64) : Bool
    result = AppDB.pool.exec(
      "UPDATE user_feeds SET last_viewed_at = NOW() WHERE user_id = $1 AND feed_id = $2",
      user_id, feed_id
    )
    result.rows_affected > 0
  end

  def self.last_viewed_at(user_id : Int64, feed_id : Int64) : Time?
    AppDB.pool.query_one?(
      "SELECT last_viewed_at FROM user_feeds WHERE user_id = $1 AND feed_id = $2",
      user_id, feed_id, as: Time?
    )
  end

  # Returns every subscriber to `feed_id` whose delivery_mode is one of the
  # active modes ('notify' or 'mp3'). Used by Delivery::Dispatch.fanout.
  def self.delivery_subscribers_for(feed_id : Int64) : Array(Subscriber)
    out = [] of Subscriber
    AppDB.pool.query_each(
      <<-SQL,
        SELECT uf.user_id, u.telegram_id, uf.delivery_mode, uf.created_at
        FROM user_feeds uf
        JOIN users u ON u.id = uf.user_id
        WHERE uf.feed_id = $1 AND uf.delivery_mode <> 'off'
      SQL
      feed_id
    ) do |rs|
      out << Subscriber.new(
        user_id:       rs.read(Int64),
        telegram_id:   rs.read(Int64),
        mode:          rs.read(String),
        subscribed_at: rs.read(Time),
      )
    end
    out
  end
end
```

- [ ] **Step 2: Wire the require into the model loader**

Modify `src/buzz_bot.cr` — find the block of `require "./models/..."` lines and add (alphabetical order):
```
require "./models/user_feed"
```
Expected: the new require sits between `require "./models/user_episode"` and the next file (whatever's next alphabetically — usually nothing else, this is the last user_*).

- [ ] **Step 3: Type-check**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: completes with no output.

- [ ] **Step 4: Commit**

```
git add src/models/user_feed.cr src/buzz_bot.cr
git commit -m "model: UserFeed — delivery_mode + last_viewed_at + subscriber lookup"
```

---

## Task 3 — Episode.upsert returns insertion flag

`feed_refresher.cr` currently treats every returned row as new. We need to know whether the row was just INSERTed (true fanout candidate) or just UPDATEd (skip — already delivered or pre-dating subscription).

**Files:**
- Modify: `src/models/episode.cr:29-45`
- Modify: `src/feed_refresher.cr:130-139`

Other call sites (`src/web/routes/feeds.cr:30`, `feeds.cr:65`, `src/web/routes/search.cr:60`) discard the return value already — no changes needed there.

- [ ] **Step 1: Add the UpsertResult record + change signature**

In `src/models/episode.cr`, replace lines 29–45 with:

```crystal
  record UpsertResult, episode : Episode, was_inserted : Bool

  # Insert-or-update an episode. Returns nil only if neither path runs
  # (current SQL guarantees a row either way; the nil branch is for safety
  # against future schema/constraint changes). The `was_inserted` flag uses
  # the standard Postgres trick: `xmax` is 0 on a fresh INSERT and set to
  # the deleter's xid on an UPDATE-from-conflict.
  def self.upsert(feed_id : Int64, guid : String, title : String, description : String?, audio_url : String, duration_sec : Int32?, published_at : Time?, image_url : String? = nil) : UpsertResult?
    AppDB.pool.query_one?(
      <<-SQL,
        INSERT INTO episodes (feed_id, guid, title, description, audio_url, duration_sec, published_at, image_url)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        ON CONFLICT (feed_id, guid) DO UPDATE SET
          title        = EXCLUDED.title,
          description  = EXCLUDED.description,
          audio_url    = EXCLUDED.audio_url,
          duration_sec = COALESCE(EXCLUDED.duration_sec, episodes.duration_sec),
          published_at = COALESCE(episodes.published_at, EXCLUDED.published_at),
          image_url    = COALESCE(EXCLUDED.image_url, episodes.image_url)
        RETURNING id, feed_id, guid, title, description, audio_url, duration_sec, published_at, image_url,
                  (xmax = 0) AS was_inserted
      SQL
      feed_id, guid, title, description, audio_url, duration_sec, published_at, image_url
    ) do |rs|
      ep = from_rs(rs)
      UpsertResult.new(episode: ep, was_inserted: rs.read(Bool))
    end
  end
```

- [ ] **Step 2: Update the feed_refresher caller**

In `src/feed_refresher.cr`, replace lines 130–139:

```crystal
    new_count      = 0
    inserted_eps   = [] of Episode
    parsed.episodes.each do |ep|
      result = Episode.upsert(
        feed.id, ep.guid, ep.title, ep.description,
        ep.audio_url, ep.duration_sec, ep.published_at, ep.image_url
      )
      next unless result
      new_count += 1
      inserted_eps << result.episode if result.was_inserted
    rescue ex
      Log.warn { "FeedRefresher: episode upsert error (feed #{feed.id}): #{ex.message}" }
    end
```

(`inserted_eps` is used in Task 7 to feed the dispatch.)

- [ ] **Step 3: Type-check**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: completes with no output.

- [ ] **Step 4: Commit**

```
git add src/models/episode.cr src/feed_refresher.cr
git commit -m "model(episode): upsert returns UpsertResult{episode, was_inserted}"
```

---

## Task 3a — Shared Mini-App-button helper + refactor `dub_result.cr`

Both the existing dub-finished notification and the new `Delivery::Notify`
build the same kind of inline button (label + Mini-App URL pointing at a
specific episode). Extract a single helper so the convention can't drift.

**Files:**
- Create: `src/bot/mini_app_link.cr`
- Create: `spec/bot/mini_app_link_spec.cr`
- Modify: `src/web/routes/dub_result.cr:126-154` (`notify_user`)

- [ ] **Step 1: Write the failing spec**

```crystal
# spec/bot/mini_app_link_spec.cr
require "../spec_helper"
require "../../src/bot/mini_app_link"

describe MiniAppLink do
  describe ".episode_button" do
    it "uses the standard '▶️ Open Episode' label" do
      btn = MiniAppLink.episode_button(123_i64)
      btn.text.should eq "▶️ Open Episode"
    end

    it "targets the Mini App's episode-specific deep link" do
      btn = MiniAppLink.episode_button(456_i64)
      url = btn.web_app.try(&.url) || ""
      url.should contain("/app?episode=456")
    end

    it "uses the configured base_url so prod vs staging stays correct" do
      btn = MiniAppLink.episode_button(789_i64)
      url = btn.web_app.try(&.url) || ""
      url.should start_with(Config.base_url)
    end
  end
end
```

- [ ] **Step 2: Run the spec to confirm it fails**

Run: `nix-shell -p crystal -p shards --run 'crystal spec spec/bot/mini_app_link_spec.cr'`
Expected: `Error: can't find file 'src/bot/mini_app_link'`.

- [ ] **Step 3: Create the helper**

```crystal
# src/bot/mini_app_link.cr
require "tourmaline"
require "../config"

# MiniAppLink — single source of truth for inline buttons that open the
# Mini App at a specific destination. Keeps bot-side notification code
# from duplicating the label/URL convention.
module MiniAppLink
  # Standard "open this episode in the Mini App" inline button. Used by
  # all bot-side notifications (dub-finished, new-episode delivery, ...).
  def self.episode_button(episode_id : Int64) : Tourmaline::InlineKeyboardButton
    Tourmaline::InlineKeyboardButton.new(
      text:    "▶️ Open Episode",
      web_app: Tourmaline::WebAppInfo.new(url: "#{Config.base_url}/app?episode=#{episode_id}"),
    )
  end
end
```

- [ ] **Step 4: Re-run the spec to confirm it passes**

Run: `nix-shell -p crystal -p shards --run 'crystal spec spec/bot/mini_app_link_spec.cr'`
Expected: `3 examples, 0 failures`.

- [ ] **Step 5: Refactor `dub_result.cr#notify_user` to use the helper**

In `src/web/routes/dub_result.cr`, locate `private def self.notify_user`
(line ~126). Replace the `reply_markup:` keyword argument inside the
`send_message` call:

Find:
```crystal
    reply_markup: Tourmaline::InlineKeyboardMarkup.new([[
      Tourmaline::InlineKeyboardButton.new(
        text: "▶️ Open Episode",
        web_app: Tourmaline::WebAppInfo.new(url: app_url)
      )
    ]])
```

Replace with:
```crystal
    reply_markup: Tourmaline::InlineKeyboardMarkup.new([[
      MiniAppLink.episode_button(episode_id)
    ]])
```

Also delete the now-unused local `app_url` line (`app_url = "#{Config.base_url}/app?episode=#{episode_id}"`) immediately above — its work is done inside the helper.

Add the require near the top of the file (alphabetical with other bot requires):
```crystal
require "../../bot/mini_app_link"
```

- [ ] **Step 6: Type-check + re-run all specs**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen && crystal spec'`
Expected: build completes silently; spec output reports the new 3 examples plus pre-existing examples, all passing.

- [ ] **Step 7: Commit**

```
git add src/bot/mini_app_link.cr spec/bot/mini_app_link_spec.cr src/web/routes/dub_result.cr
git commit -m "bot: MiniAppLink.episode_button — shared by dub-result + delivery notify"
```

---

## Task 3b — Extend `AudioSender.send_to_user` with optional `caption:`

The new `mp3` delivery mode wants a one-line caption ("Feed · pub-date") under
the audio bubble. The existing manual Send-to-Chat caller passes nil and
keeps its current behavior unchanged.

**Files:**
- Modify: `src/bot/audio_sender.cr`

- [ ] **Step 1: Add the parameter to `send_to_user`**

In `src/bot/audio_sender.cr`, change the public signature (around line 23):

From:
```crystal
  def self.send_to_user(telegram_id : Int64, episode : Episode, feed : Feed?, override_url : String? = nil)
    audio_url = override_url || episode.audio_url
    if try_url_send(telegram_id, episode, feed, audio_url)
```

To:
```crystal
  def self.send_to_user(telegram_id : Int64, episode : Episode, feed : Feed?,
                        override_url : String? = nil, caption : String? = nil)
    audio_url = override_url || episode.audio_url
    if try_url_send(telegram_id, episode, feed, audio_url, caption)
```

And in the same method, update the fallback `download_and_upload` call site:
```crystal
    download_and_upload(telegram_id, episode, feed, audio_url, caption)
```

- [ ] **Step 2: Thread `caption` through the fast path**

Replace `private def self.try_url_send` (the JSON-payload fast path around
lines 51–70). New signature + payload:

```crystal
  private def self.try_url_send(telegram_id : Int64, episode : Episode, feed : Feed?,
                                 audio_url : String, caption : String?) : Bool
    body = JSON.build do |j|
      j.object do
        j.field "chat_id", telegram_id
        j.field "audio",   audio_url
        j.field "title",   episode.title
        j.field "performer", feed.try(&.title) || ""
        episode.duration_sec.try { |d| j.field "duration", d }
        caption.try { |c| j.field "caption", c unless c.empty? }
      end
    end

    uri    = URI.parse("#{TELEGRAM_API}/sendAudio")
    client = HTTP::Client.new(uri)
    client.read_timeout = URL_SEND_TIMEOUT
    resp = client.post(uri.path, headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body)
    JSON.parse(resp.body)["ok"]?.try(&.as_bool?) || false
  rescue ex
    Log.warn { "AudioSender URL send failed: #{ex.message}" }
    false
  end
```

- [ ] **Step 3: Thread `caption` through the slow path**

Update `private def self.download_and_upload` signature (around line 75):
```crystal
  private def self.download_and_upload(telegram_id : Int64, episode : Episode,
                                        feed : Feed?, audio_url : String,
                                        caption : String?)
```

And the `upload_multipart` invocation inside its body (the `rewind` block):
```crystal
      tempfile.rewind
      upload_multipart(telegram_id, episode, feed, tempfile, caption)
```

Then update `upload_multipart` signature + form-data field (around line 117):
```crystal
  private def self.upload_multipart(telegram_id : Int64, episode : Episode,
                                     feed : Feed?, file : File,
                                     caption : String?)
    boundary = "BuzzBot#{Random::Secure.hex(10)}"
    tmp = File.tempfile("buzz-multipart", ".bin")
    begin
      builder = HTTP::FormData::Builder.new(tmp, boundary)
      builder.field("chat_id",   telegram_id.to_s)
      builder.field("title",     episode.title)
      builder.field("performer", feed.try(&.title) || "")
      episode.duration_sec.try { |d| builder.field("duration", d.to_s) }
      caption.try { |c| builder.field("caption", c) unless c.empty? }
      builder.file(
        "audio", file,
        HTTP::FormData::FileMetadata.new(filename: "episode.mp3"),
        HTTP::Headers{"Content-Type" => "audio/mpeg"}
      )
      builder.finish
      # … rest unchanged
```

- [ ] **Step 4: Type-check the whole tree**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: completes with no output.

- [ ] **Step 5: Verify the existing /episodes/:id/send caller is untouched**

Run: `grep -n 'AudioSender.send_to_user' src/web/routes/episodes.cr`
Expected: one match, with `override_url` keyword (no caption). The nil-default
preserves identical behavior at this call site.

- [ ] **Step 6: Commit**

```
git add src/bot/audio_sender.cr
git commit -m "bot(audio_sender): optional caption param (nil default; existing caller unchanged)"
```

---

## Task 4 — Notify-mode formatter

Pure-ish formatter that wraps the Telegram `send_photo` call. Caption building is split out as a pure helper so it can be unit-tested.

**Files:**
- Create: `src/delivery/notify.cr`
- Create: `spec/delivery/notify_spec.cr`

- [ ] **Step 1: Write the failing spec**

```crystal
# spec/delivery/notify_spec.cr
require "../spec_helper"
require "../../src/delivery/notify"

describe Delivery::Notify do
  describe ".build_caption" do
    it "includes feed title, episode title, date, and duration" do
      caption = Delivery::Notify.build_caption(
        feed_title:    "NRC Vandaag",
        episode_title: "In Ter Apel voelt iedereen zich in de…",
        published_at:  Time.utc(2026, 5, 28, 9, 0, 0),
        duration_sec:  18 * 60,
      )

      caption.should contain("*NRC Vandaag*")
      caption.should contain("new episode")
      caption.should contain("In Ter Apel voelt iedereen zich in de…")
      caption.should contain("May 28, 2026")
      caption.should contain("18 min")
    end

    it "omits duration when nil" do
      caption = Delivery::Notify.build_caption(
        feed_title:    "Daily",
        episode_title: "Untitled",
        published_at:  Time.utc(2026, 1, 2),
        duration_sec:  nil,
      )

      caption.should_not contain("min")
      caption.should contain("Jan 2, 2026")
    end

    it "omits date when published_at is nil" do
      caption = Delivery::Notify.build_caption(
        feed_title:    "Daily",
        episode_title: "Untitled",
        published_at:  nil,
        duration_sec:  300,
      )

      caption.should_not contain(",")
      caption.should contain("5 min")
    end

    it "formats hours and minutes for long episodes" do
      caption = Delivery::Notify.build_caption(
        feed_title:    "Hardcore History",
        episode_title: "Wrath of the Khans",
        published_at:  Time.utc(2026, 5, 1),
        duration_sec:  3 * 3600 + 25 * 60,
      )

      caption.should contain("3h 25m")
    end
  end
end
```

- [ ] **Step 2: Run the spec to confirm it fails**

Run: `nix-shell -p crystal -p shards --run 'crystal spec spec/delivery/notify_spec.cr'`
Expected: `Error: can't find file 'src/delivery/notify'` (or `undefined constant Delivery::Notify`).

- [ ] **Step 3: Implement the module**

```crystal
# src/delivery/notify.cr
require "tourmaline"
require "../bot/client"
require "../bot/mini_app_link"
require "../config"
require "../models/feed"
require "../models/episode"

# Delivery::Notify — formats and sends the "notify" mode Telegram card.
# A card is a send_photo (when feed.image_url is present) with the episode
# title in the caption and a Mini-App-launching Listen button; falls back
# to send_message with the same text/button when no cover or when
# send_photo fails (bad URL, upstream 404, etc).
module Delivery::Notify
  MONTH_ABBR = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]

  # Pure: build the markdown caption. Extracted so it's unit-testable.
  def self.build_caption(feed_title : String, episode_title : String,
                          published_at : Time?, duration_sec : Int32?) : String
    parts = ["*#{feed_title}* · new episode", episode_title]

    meta = [] of String
    if (pub = published_at)
      meta << "#{MONTH_ABBR[pub.month - 1]} #{pub.day}, #{pub.year}"
    end
    if (sec = duration_sec) && sec > 0
      meta << fmt_duration(sec)
    end
    parts << meta.join(" · ") unless meta.empty?

    parts.join("\n")
  end

  def self.send(telegram_id : Int64, feed : Feed, episode : Episode)
    caption = build_caption(
      feed_title:    feed.title || "Podcast",
      episode_title: episode.title,
      published_at:  episode.published_at,
      duration_sec:  episode.duration_sec,
    )

    # Standard inline button — shared with dub-result notifications via
    # MiniAppLink (introduced in Task 3a).
    markup = Tourmaline::InlineKeyboardMarkup.new([[
      MiniAppLink.episode_button(episode.id),
    ]])

    if (img = feed.image_url)
      begin
        BotClient.client.send_photo(
          chat_id:      telegram_id,
          photo:        img,
          caption:      caption,
          parse_mode:   Tourmaline::ParseMode::Markdown,
          reply_markup: markup,
        )
        Log.info { "Delivery[notify ep=#{episode.id} tg=#{telegram_id}]: photo sent" }
        return
      rescue ex
        Log.warn { "Delivery[notify ep=#{episode.id} tg=#{telegram_id}]: photo send failed (#{ex.message}) — falling back to text" }
      end
    end

    BotClient.client.send_message(
      telegram_id, caption,
      parse_mode:   Tourmaline::ParseMode::Markdown,
      reply_markup: markup,
    )
    Log.info { "Delivery[notify ep=#{episode.id} tg=#{telegram_id}]: text sent" }
  rescue ex
    Log.error { "Delivery[notify ep=#{episode.id} tg=#{telegram_id}]: send failed — #{ex.message}" }
  end

  private def self.fmt_duration(sec : Int32) : String
    h = sec // 3600
    m = (sec % 3600) // 60
    h > 0 ? "#{h}h #{m}m" : "#{m} min"
  end
end
```

- [ ] **Step 4: Re-run the spec to confirm it passes**

Run: `nix-shell -p crystal -p shards --run 'crystal spec spec/delivery/notify_spec.cr'`
Expected: `4 examples, 0 failures`.

- [ ] **Step 5: Type-check the whole tree**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: completes with no output.

- [ ] **Step 6: Commit**

```
git add src/delivery/notify.cr spec/delivery/notify_spec.cr
git commit -m "delivery: Notify.send — Telegram card with text-fallback + Mini App button"
```

---

## Task 5 — Delivery::Dispatch eligibility filter (pure, tested)

The eligibility filter is the easily-testable part of the fanout: given a list of subscribers and a list of episodes, produce the (subscriber, episode) targets that should actually receive a delivery. Side-effect-free; perfect for a spec.

**Files:**
- Create: `src/delivery/dispatch.cr` (eligibility filter + records only this task; full `fanout` arrives in Task 6)
- Create: `spec/delivery/dispatch_spec.cr`

- [ ] **Step 1: Write the failing spec**

```crystal
# spec/delivery/dispatch_spec.cr
require "../spec_helper"
require "../../src/delivery/dispatch"

private def sub(user_id, mode, subscribed_at)
  Delivery::Dispatch::Subscriber.new(
    user_id: user_id.to_i64, telegram_id: (user_id * 10).to_i64,
    mode: mode, subscribed_at: subscribed_at
  )
end

private def ep(id, published_at, audio_url = "https://example.com/a.mp3")
  Delivery::Dispatch::EpisodeRef.new(
    id: id.to_i64, published_at: published_at, audio_url: audio_url
  )
end

private def t(s) Time.parse_utc(s, "%Y-%m-%dT%H:%M:%S") end

describe Delivery::Dispatch do
  describe ".eligible_targets" do
    it "yields one target per (subscriber, episode) pair with mode notify or mp3" do
      subs = [sub(1, "notify", t("2026-01-01T00:00:00"))]
      eps  = [ep(100, t("2026-02-01T00:00:00")), ep(101, t("2026-02-02T00:00:00"))]

      result = Delivery::Dispatch.eligible_targets(subs, eps)

      result.size.should eq 2
      result.map(&.subscriber.user_id).should eq [1_i64, 1_i64]
      result.map(&.episode.id).should eq [100_i64, 101_i64]
    end

    it "skips subscribers in 'off' mode" do
      subs = [sub(1, "off", t("2026-01-01T00:00:00"))]
      eps  = [ep(100, t("2026-02-01T00:00:00"))]

      Delivery::Dispatch.eligible_targets(subs, eps).should be_empty
    end

    it "skips episodes published before the user subscribed (backfill protection)" do
      subs = [sub(1, "notify", t("2026-03-01T00:00:00"))]
      eps  = [
        ep(100, t("2026-01-01T00:00:00")),  # before subscription — skip
        ep(101, t("2026-04-01T00:00:00")),  # after subscription  — keep
      ]

      result = Delivery::Dispatch.eligible_targets(subs, eps)

      result.size.should eq 1
      result[0].episode.id.should eq 101_i64
    end

    it "skips episodes with nil published_at" do
      subs = [sub(1, "notify", t("2026-01-01T00:00:00"))]
      eps  = [ep(100, nil)]

      Delivery::Dispatch.eligible_targets(subs, eps).should be_empty
    end

    it "skips episodes with empty audio_url" do
      subs = [sub(1, "mp3", t("2026-01-01T00:00:00"))]
      eps  = [ep(100, t("2026-02-01T00:00:00"), audio_url: "")]

      Delivery::Dispatch.eligible_targets(subs, eps).should be_empty
    end

    it "produces a cartesian product when there are multiple subscribers and episodes" do
      subs = [
        sub(1, "notify", t("2026-01-01T00:00:00")),
        sub(2, "mp3",    t("2026-01-15T00:00:00")),
      ]
      eps = [
        ep(100, t("2026-02-01T00:00:00")),
        ep(101, t("2026-02-02T00:00:00")),
      ]

      result = Delivery::Dispatch.eligible_targets(subs, eps)
      result.size.should eq 4
      modes = result.map(&.subscriber.mode).tally
      modes["notify"].should eq 2
      modes["mp3"].should eq 2
    end
  end
end
```

- [ ] **Step 2: Run the spec to confirm it fails**

Run: `nix-shell -p crystal -p shards --run 'crystal spec spec/delivery/dispatch_spec.cr'`
Expected: `Error: can't find file 'src/delivery/dispatch'`.

- [ ] **Step 3: Implement the records + pure filter**

```crystal
# src/delivery/dispatch.cr
require "../models/feed"
require "../models/episode"
require "../models/user_feed"

# Delivery::Dispatch — fans episodes out to subscribers per their delivery_mode.
#
# `eligible_targets` is the pure heart of the module: given subscriber and
# episode projections, it computes which (subscriber, episode) combinations
# should actually receive a Telegram delivery. Backfill protection lives here:
# only episodes published AFTER the user subscribed are delivered.
#
# `fanout` (added in the next task) wires this to the real models + side
# effects (spawn per target, call Notify or AudioSender by mode).
module Delivery::Dispatch
  record Subscriber,
    user_id       : Int64,
    telegram_id   : Int64,
    mode          : String,
    subscribed_at : Time

  record EpisodeRef,
    id           : Int64,
    published_at : Time?,
    audio_url    : String

  record Target,
    subscriber : Subscriber,
    episode    : EpisodeRef

  def self.eligible_targets(subscribers : Array(Subscriber), episodes : Array(EpisodeRef)) : Array(Target)
    out = [] of Target
    subscribers.each do |sub|
      next if sub.mode == "off"
      episodes.each do |ep|
        next if ep.audio_url.empty?
        pub = ep.published_at
        next if pub.nil?
        next unless sub.subscribed_at < pub
        out << Target.new(subscriber: sub, episode: ep)
      end
    end
    out
  end
end
```

- [ ] **Step 4: Re-run the spec to confirm it passes**

Run: `nix-shell -p crystal -p shards --run 'crystal spec spec/delivery/dispatch_spec.cr'`
Expected: `6 examples, 0 failures`.

- [ ] **Step 5: Type-check**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: completes with no output.

- [ ] **Step 6: Commit**

```
git add src/delivery/dispatch.cr spec/delivery/dispatch_spec.cr
git commit -m "delivery: Dispatch records + eligible_targets pure filter (backfill-safe)"
```

---

## Task 6 — Delivery::Dispatch.fanout — side-effect wrapper

Adds `fanout(feed, episodes)` on top of the pure filter from Task 5. Spawns one fiber per target so the RSS refresh isn't blocked by Telegram round-trips.

**Files:**
- Modify: `src/delivery/dispatch.cr`

- [ ] **Step 1: Add the fanout method**

In `src/delivery/dispatch.cr`, *after* the `eligible_targets` method (still inside the `module Delivery::Dispatch` block), append:

```crystal
  # Fanout entry called from FeedRefresher after a refresh batch. Builds
  # subscriber + episode projections, runs the eligibility filter, and spawns
  # one fiber per target — same fire-and-forget pattern used for /episodes/:id/send.
  def self.fanout(feed : Feed, episodes : Array(Episode))
    return if episodes.empty?

    subs = UserFeed.delivery_subscribers_for(feed.id)
    return if subs.empty?

    sub_refs = subs.map do |s|
      Subscriber.new(
        user_id: s.user_id, telegram_id: s.telegram_id,
        mode: s.mode, subscribed_at: s.subscribed_at,
      )
    end

    ep_index = episodes.each_with_object({} of Int64 => Episode) { |e, h| h[e.id] = e }
    ep_refs  = episodes.map do |e|
      EpisodeRef.new(id: e.id, published_at: e.published_at, audio_url: e.audio_url)
    end

    targets = eligible_targets(sub_refs, ep_refs)
    return if targets.empty?

    Log.info { "Delivery::Dispatch[feed=#{feed.id}]: #{targets.size} targets across #{episodes.size} episodes" }

    targets.each do |target|
      ep = ep_index[target.episode.id]
      sub = target.subscriber
      spawn(name: "delivery-#{sub.user_id}-#{ep.id}") do
        case sub.mode
        when "notify"
          Delivery::Notify.send(sub.telegram_id, feed, ep)
        when "mp3"
          # Caption appears as a text line below the audio bubble.
          # AudioSender's title/performer fields already populate the
          # bubble itself; the caption adds the publish date.
          caption = build_mp3_caption(feed, ep)
          AudioSender.send_to_user(sub.telegram_id, ep, feed, caption: caption)
        end
      end
    end
  end

  # Pure helper — extracted so it could be tested if desired. Format:
  # "Feed Title · May 28, 2026" (date omitted when published_at is nil).
  private MP3_MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]
  private def self.build_mp3_caption(feed : Feed, ep : Episode) : String?
    title = feed.title || "Podcast"
    if (pub = ep.published_at)
      "#{title} · #{MP3_MONTHS[pub.month - 1]} #{pub.day}, #{pub.year}"
    else
      title
    end
  end
end
```

Also add the missing `require` at the top of the file (above the existing requires):
```crystal
require "../bot/audio_sender"
require "./notify"
```

- [ ] **Step 2: Type-check**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: completes with no output.

- [ ] **Step 3: Re-run the dispatch spec to confirm nothing regressed**

Run: `nix-shell -p crystal -p shards --run 'crystal spec spec/delivery/dispatch_spec.cr'`
Expected: `6 examples, 0 failures`.

- [ ] **Step 4: Commit**

```
git add src/delivery/dispatch.cr
git commit -m "delivery: Dispatch.fanout — spawn per target, route by mode"
```

---

## Task 7 — Wire fanout into FeedRefresher

`feed_refresher.cr` already computes `inserted_eps` (Task 3). Now we hand it off.

**Files:**
- Modify: `src/feed_refresher.cr:1`, `:140-144` (around the existing log line at the bottom of `refresh`)

- [ ] **Step 1: Add the require**

At the top of `src/feed_refresher.cr` (with the other `require`s if any exist, or just after the file's docstring), add:
```crystal
require "./delivery/dispatch"
```

- [ ] **Step 2: Call fanout after the upsert loop**

In `src/feed_refresher.cr`, after the `end` that closes the `parsed.episodes.each` block but *before* the final `label = ...` / `Log.info` lines, insert:

```crystal
    Delivery::Dispatch.fanout(feed, inserted_eps)
```

So the bottom of `refresh` reads:
```crystal
    parsed.episodes.each do |ep|
      result = Episode.upsert(...)
      next unless result
      new_count += 1
      inserted_eps << result.episode if result.was_inserted
    rescue ex
      Log.warn { "FeedRefresher: episode upsert error (feed #{feed.id}): #{ex.message}" }
    end

    Delivery::Dispatch.fanout(feed, inserted_eps)

    label = feed.title || feed.url
    Log.info { "FeedRefresher: feed #{feed.id} \"#{label}\" — #{new_count} new/updated episodes" }
  rescue ex
    Log.error { "FeedRefresher: error refreshing feed #{feed.id}: #{ex.message}" }
  end
```

- [ ] **Step 3: Type-check**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: completes with no output.

- [ ] **Step 4: Commit**

```
git add src/feed_refresher.cr
git commit -m "refresher: fan out inserted episodes via Delivery::Dispatch"
```

---

## Task 8 — PATCH /feeds/:id/delivery_mode route

**Files:**
- Modify: `src/web/routes/feeds.cr` (locate the `register` method's end)

- [ ] **Step 1: Add the route**

Inside `Web::Routes::Feeds.register`, after the existing routes but before the closing `end`, add:

```crystal
    patch "/feeds/:id/delivery_mode" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feed_id = env.params.url["id"].to_i64?
      halt env, status_code: 400, response: %({"error":"bad_feed_id"}) unless feed_id

      body = env.request.body.try(&.gets_to_end) || "{}"
      data = JSON.parse(body) rescue halt env, status_code: 400, response: %({"error":"invalid_json"})
      mode = data["mode"]?.try(&.as_s?) || ""

      unless UserFeed::VALID_DELIVERY_MODES.includes?(mode)
        env.response.status_code = 400
        env.response.content_type = "application/json"
        next %({"error":"invalid_mode","allowed":["off","notify","mp3"]})
      end

      # Premium gate for mp3 mode — matches the manual Send-to-Chat gate at
      # POST /episodes/:id/send. Without this, auto-delivery would trivially
      # bypass the existing manual-feature premium gate.
      if mode == "mp3" && !user.subscribed?
        env.response.status_code = 402
        env.response.content_type = "application/json"
        next %({"error":"premium_required"})
      end

      updated = UserFeed.set_delivery_mode(user.id, feed_id, mode)
      unless updated
        env.response.status_code = 404
        env.response.content_type = "application/json"
        next %({"error":"not_subscribed"})
      end

      env.response.status_code = 204
      nil
    end
```

Also ensure the file's `require` block includes the new model — at the top, add:
```crystal
require "../../models/user_feed"
```
(if not already present from another change).

- [ ] **Step 2: Type-check**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: completes with no output.

- [ ] **Step 3: Smoke-test locally with curl** *(operator step — skip if no local server)*

Start the server with `BOT_TOKEN=dummy DATABASE_URL=... crystal run src/buzz_bot.cr`, then:
```
curl -X PATCH http://127.0.0.1:3000/feeds/1/delivery_mode \
  -H 'Content-Type: application/json' \
  -H 'X-Init-Data: <valid initData>' \
  -d '{"mode":"notify"}' -i
```
Expected: `HTTP/1.1 204 No Content`. Invalid mode → `400 invalid_mode`. Unknown feed id → `404 not_subscribed`.

- [ ] **Step 4: Commit**

```
git add src/web/routes/feeds.cr
git commit -m "route: PATCH /feeds/:id/delivery_mode (off|notify|mp3)"
```

---

## Task 9 — POST /feeds/:id/viewed route

**Files:**
- Modify: `src/web/routes/feeds.cr`

- [ ] **Step 1: Add the route**

Inside `Web::Routes::Feeds.register`, after the route from Task 8, add:

```crystal
    post "/feeds/:id/viewed" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feed_id = env.params.url["id"].to_i64?
      halt env, status_code: 400, response: %({"error":"bad_feed_id"}) unless feed_id

      UserFeed.touch_viewed(user.id, feed_id)
      env.response.status_code = 204
      nil
    end
```

Note: idempotent + safe even if no user_feeds row exists (`touch_viewed` returns false silently, route still 204s — the alternative of 404'ing would just spam errors during race conditions and offers no UX value).

- [ ] **Step 2: Type-check**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: completes with no output.

- [ ] **Step 3: Commit**

```
git add src/web/routes/feeds.cr
git commit -m "route: POST /feeds/:id/viewed — bump last_viewed_at"
```

---

## Task 10 — Extend GET /episodes response

Add `delivery_mode` and `new_episode_ids` to the JSON returned by `GET /episodes?feed_id=…`.

**Files:**
- Modify: `src/web/routes/episodes.cr:41-92`

- [ ] **Step 1: Compute the new fields and include them in the response**

In `src/web/routes/episodes.cr`, replace lines 88–91 (the end of the `get "/episodes"` handler — the `items = ...` and JSON-emit lines):

```crystal
      items = Web.build_episode_list(episodes, user.id)

      delivery_mode = UserFeed.get_delivery_mode(user.id, feed_id)

      new_ids = if (lv = UserFeed.last_viewed_at(user.id, feed_id))
        episodes.compact_map { |ep| ep.id if (pub = ep.published_at) && pub > lv }
      else
        # First-ever view of this feed: treat everything as already-seen so
        # we don't blast NEW badges across the entire history on day one.
        [] of Int64
      end

      env.response.content_type = "application/json"
      {
        episodes:        items,
        has_more:        has_more,
        episode_order:   order,
        delivery_mode:   delivery_mode,
        new_episode_ids: new_ids,
        # Premium status drives the chip's mp3 gating (skip cycle, show
        # upsell banner on attempt). Returning it here keeps the per-feed
        # view self-contained — no coupling to the player JSON fetch.
        is_premium:      user.subscribed?,
      }.to_json
```

Also ensure the `require` at the top of `src/web/routes/episodes.cr` includes:
```crystal
require "../../models/user_feed"
```

- [ ] **Step 2: Type-check**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: completes with no output.

- [ ] **Step 3: Commit**

```
git add src/web/routes/episodes.cr
git commit -m "route(episodes): include delivery_mode + new_episode_ids in response"
```

---

## Task 11 — CLJS db slice extension

Add the three new keys to the `:episodes` slice so subscriptions can be wired before any feature code references them.

**Files:**
- Modify: `src/cljs/buzz_bot/db.cljs`

- [ ] **Step 1: Extend the :episodes default**

Find the `:episodes` map inside the default app-db (search for `:episodes {`). Add three keys, preserving the existing ones:

```clojure
   :episodes {:feed-id          nil
              :list             []
              :offset           0
              :has-more?        false
              :order            :desc
              :loading?         false
              ;; NEW — delivery feature
              :delivery-mode    :off
              :new-episode-ids  #{}
              :delivery-pending nil
              :delivery-upsell? false   ; non-premium tried mp3; show banner
              :is-premium?      false}  ; seeded from /episodes response
```

(If the existing literal differs in field order or includes other keys, leave them; just append the three new ones.)

- [ ] **Step 2: Compile the CLJS app build to confirm nothing breaks**

Run: `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs compile app'`
Expected: `[:app] Build completed. (… files, 0 warnings)`.

- [ ] **Step 3: Commit**

```
git add src/cljs/buzz_bot/db.cljs
git commit -m "cljs(db): extend :episodes with delivery-mode + new-episode-ids"
```

---

## Task 12 — CLJS pure helpers + tests

Pure ClojureScript helpers used by the chip, badge, and event handlers. Tests-first.

**Files:**
- Create: `src/cljs/buzz_bot/delivery.cljs`
- Create: `test/buzz_bot/delivery_test.cljs`

- [ ] **Step 1: Write the failing tests**

```clojure
;; test/buzz_bot/delivery_test.cljs
(ns buzz-bot.delivery-test
  (:require [cljs.test :refer [deftest is testing]]
            [buzz-bot.delivery :as d]))

(deftest next-mode-cycles-off-notify-mp3-off-for-premium
  (is (= :notify (d/next-mode :off    true)))
  (is (= :mp3    (d/next-mode :notify true)))
  (is (= :off    (d/next-mode :mp3    true))))

(deftest next-mode-skips-mp3-for-non-premium
  ;; cycle shortens to off ↔ notify so tap-cycle never lands on mp3
  ;; without entitlement (matches the Send-to-Chat premium gate).
  (is (= :notify (d/next-mode :off    false)))
  (is (= :off    (d/next-mode :notify false)))
  ;; if state somehow holds :mp3 (e.g. premium expired), cycle back to off
  (is (= :off    (d/next-mode :mp3    false))))

(deftest next-mode-defaults-unknown-to-off
  (is (= :off (d/next-mode nil           true)))
  (is (= :off (d/next-mode nil           false)))
  (is (= :off (d/next-mode :anything-else true))))

(deftest mode-label-matches-spec
  (is (= "In-app only" (d/mode->label :off)))
  (is (= "Notify me"   (d/mode->label :notify)))
  (is (= "Send MP3"    (d/mode->label :mp3))))

(deftest mode-icon-key-matches-spec
  (is (= :bell-off (d/mode->icon-key :off)))
  (is (= :bell     (d/mode->icon-key :notify)))
  (is (= :mp3      (d/mode->icon-key :mp3))))

(deftest new?-true-for-id-in-set-false-otherwise
  (is (true?  (d/new? #{1 2 3} 2)))
  (is (false? (d/new? #{1 2 3} 4)))
  (is (false? (d/new? #{} 1)))
  (is (false? (d/new? nil 1))))

(deftest new?-coerces-id-to-number
  ;; Server returns numeric ids; UI may pass them through as strings via :data-* attrs.
  (is (true? (d/new? #{123} "123")))
  (is (true? (d/new? #{123} 123))))
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `nix-shell -p jdk21_headless --run 'npm test'`
Expected: `Could not find resource buzz_bot.delivery` or test compile error.

- [ ] **Step 3: Implement the helpers**

```clojure
;; src/cljs/buzz_bot/delivery.cljs
(ns buzz-bot.delivery
  "Pure helpers for the per-feed delivery feature — mode cycling, labels,
   icon-key mapping, NEW-badge predicate. No re-frame, no DOM, no Telegram
   SDK; safe to unit-test under shadow-cljs :node-test.")

(defn next-mode
  "Cycle off → notify → mp3 → off (premium) or off ↔ notify (non-premium).
   Unknown / nil input → :off. The premium-aware variant matches the
   Send-to-Chat premium gate so tap-cycle never advances to mp3 without
   entitlement; the long-press popup is the only path that surfaces the
   mp3 option (and shows an upsell when picked without premium)."
  [mode premium?]
  (case mode
    :off    :notify
    :notify (if premium? :mp3 :off)
    :mp3    :off
    :off))

(defn mode->label [mode]
  (case mode
    :off    "In-app only"
    :notify "Notify me"
    :mp3    "Send MP3"
    "In-app only"))

(defn mode->icon-key
  "Maps the mode to an icon-key the view layer resolves into the actual SVG.
   Keeping this as a keyword instead of inline hiccup keeps it testable
   without pulling DOM helpers into the helpers ns."
  [mode]
  (case mode
    :off    :bell-off
    :notify :bell
    :mp3    :mp3
    :bell-off))

(defn new?
  "True iff `id` (number or string-of-number) is in `id-set`. Returns false
   when id-set is nil or empty — callers always render unconditionally."
  [id-set id]
  (let [n (cond
            (number? id) id
            (string? id) (js/parseInt id 10)
            :else        nil)]
    (boolean (and id-set n (contains? id-set n)))))
```

- [ ] **Step 4: Re-run the tests to confirm they pass**

Run: `nix-shell -p jdk21_headless --run 'npm test'`
Expected: `Ran N tests containing M assertions. 0 failures, 0 errors.` (N grows by 7 from the previous run; M grows by 16 — 3 premium / 3 non-premium / 3 unknown-defaults / 3 mode-label / 3 mode-icon-key / 4 new? cases.)

- [ ] **Step 5: Commit**

```
git add src/cljs/buzz_bot/delivery.cljs test/buzz_bot/delivery_test.cljs
git commit -m "cljs(delivery): pure helpers (next-mode, mode->label, mode->icon-key, new?)"
```

---

## Task 13 — CLJS subs

Add the three new subscriptions that the view will consume.

**Files:**
- Modify: `src/cljs/buzz_bot/subs.cljs`

- [ ] **Step 1: Add the subs**

Find the existing `::episodes-*` subs (search for `:buzz-bot.subs/episodes-list` or similar) and add three siblings:

```clojure
(rf/reg-sub ::delivery-mode
  :<- [::episodes]
  (fn [e _] (or (:delivery-mode e) :off)))

(rf/reg-sub ::delivery-pending
  :<- [::episodes]
  (fn [e _] (:delivery-pending e)))

(rf/reg-sub ::delivery-upsell?
  :<- [::episodes]
  (fn [e _] (boolean (:delivery-upsell? e))))

(rf/reg-sub ::is-premium?
  :<- [::episodes]
  (fn [e _] (boolean (:is-premium? e))))

(rf/reg-sub ::new-episode-ids
  :<- [::episodes]
  (fn [e _] (or (:new-episode-ids e) #{})))
```

(If `::episodes` sub doesn't exist yet, add it: `(rf/reg-sub ::episodes (fn [db _] (:episodes db)))`.)

- [ ] **Step 2: Compile the app build**

Run: `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs compile app'`
Expected: clean.

- [ ] **Step 3: Commit**

```
git add src/cljs/buzz_bot/subs.cljs
git commit -m "cljs(subs): delivery-mode, delivery-pending, new-episode-ids"
```

---

## Task 14 — CLJS events: delivery cycle/set + patch ok/err

Adds the optimistic-update events that talk to the new PATCH route.

**Files:**
- Modify: `src/cljs/buzz_bot/events.cljs`

- [ ] **Step 1: Add the events**

Append (anywhere — convention is near the other `:episodes` events; search for `::fetch-episodes`):

```clojure
;; Cycle delivery mode for the current feed. Optimistic UI: write the new
;; mode immediately to db, fire PATCH; on err revert. The premium flag
;; shortens the cycle to off↔notify for non-premium users so tap-cycle
;; never lands on mp3 without entitlement (matches Send-to-Chat gate).
(rf/reg-event-fx
 ::cycle-delivery-mode
 (fn [{:keys [db]} [_ feed-id]]
   (let [current   (or (get-in db [:episodes :delivery-mode]) :off)
         premium?  (boolean (get-in db [:episodes :is-premium?]))
         next-m    (buzz-bot.delivery/next-mode current premium?)]
     {:dispatch [::set-delivery-mode feed-id next-m]})))

(rf/reg-event-fx
 ::set-delivery-mode
 (fn [{:keys [db]} [_ feed-id mode]]
   (let [prior     (or (get-in db [:episodes :delivery-mode]) :off)
         premium?  (boolean (get-in db [:episodes :is-premium?]))]
     (cond
       (= prior mode)
       {}

       ;; Non-premium user picked mp3 from the long-press popup → no
       ;; optimistic write, no PATCH; just surface the upsell banner.
       (and (= mode :mp3) (not premium?))
       {:db (assoc-in db [:episodes :delivery-upsell?] true)}

       :else
       {:db (-> db
                (assoc-in [:episodes :delivery-mode]    mode)
                (assoc-in [:episodes :delivery-pending] prior)
                (assoc-in [:episodes :delivery-upsell?] false))
        ::buzz-bot.fx/http-fetch
        {:method :patch
         :url    (str "/feeds/" feed-id "/delivery_mode")
         :body   {:mode (name mode)}
         :on-ok  [::delivery-patch-ok]
         :on-err [::delivery-patch-err]}}))))

(rf/reg-event-db
 ::delivery-patch-ok
 (fn [db _]
   (assoc-in db [:episodes :delivery-pending] nil)))

(rf/reg-event-db
 ::delivery-patch-err
 (fn [db [_ err]]
   ;; Revert to the prior mode and clear pending. If err is HTTP 402
   ;; (premium_required — e.g. premium expired between fetch and PATCH),
   ;; also flip the upsell banner on.
   (let [prior  (get-in db [:episodes :delivery-pending])
         402?   (and (string? err) (clojure.string/includes? err "402"))]
     (-> db
         (assoc-in [:episodes :delivery-mode]    (or prior :off))
         (assoc-in [:episodes :delivery-pending] nil)
         (cond-> 402?
           (assoc-in [:episodes :delivery-upsell?] true))))))

(rf/reg-event-db
 ::dismiss-delivery-upsell
 (fn [db _]
   (assoc-in db [:episodes :delivery-upsell?] false)))

;; Bump last_viewed_at server-side and clear local NEW marks. Fire-and-forget;
;; failure is silent — the badge will just reappear on next fetch.
(rf/reg-event-fx
 ::mark-feed-viewed
 (fn [{:keys [db]} [_ feed-id]]
   {:db (assoc-in db [:episodes :new-episode-ids] #{})
    ::buzz-bot.fx/http-fetch
    {:method :post
     :url    (str "/feeds/" feed-id "/viewed")
     :on-ok  [::noop]
     :on-err [::noop]}}))

(rf/reg-event-db ::noop (fn [db _] db))
```

If `::noop` is already defined elsewhere in the file, drop the last line.

Also ensure the require block at the top of `src/cljs/buzz_bot/events.cljs` includes:
```clojure
[buzz-bot.delivery]
[clojure.string :as str]   ;; for the 402 substring check
```
(If `clojure.string` is already aliased elsewhere in the file, swap the
`clojure.string/includes?` call above to `(str/includes? err "402")`.)

- [ ] **Step 2: Verify the http-fetch fx supports :patch**

`src/cljs/buzz_bot/fx.cljs` `build-init` has a `method-str` helper. Open it. If `:patch` isn't in the `case`, add it:
```clojure
(defn- method-str [m]
  (case m :get "GET" :post "POST" :put "PUT" :patch "PATCH" :delete "DELETE" "GET"))
```

- [ ] **Step 3: Compile the app build**

Run: `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs compile app'`
Expected: clean.

- [ ] **Step 4: Commit**

```
git add src/cljs/buzz_bot/events.cljs src/cljs/buzz_bot/fx.cljs
git commit -m "cljs(events): cycle/set delivery-mode + mark-feed-viewed (optimistic)"
```

---

## Task 15 — Extend ::episodes-loaded handler

`::fetch-episodes` already populates `:list`/`:has-more?`/`:order`. The handler now also seeds `:delivery-mode` and `:new-episode-ids` from the response.

**Files:**
- Modify: `src/cljs/buzz_bot/events.cljs` (find `::episodes-loaded`)

- [ ] **Step 1: Extend the response handler**

Locate the existing `::episodes-loaded` reg-event-* (it's `reg-event-fx`, around line 263). Find the `db'` `let` binding inside, and extend it with the two new fields. The complete handler becomes:

```clojure
(rf/reg-event-fx
 ::episodes-loaded
 (fn [{:keys [db]} [_ resp]]
   (let [restore-id (get-in db [:episodes :restore-to-id])
         server-order (some-> (:episode_order resp) keyword)
         delivery     (some-> (:delivery_mode resp) keyword)
         new-ids      (set (:new_episode_ids resp))
         premium?     (boolean (:is_premium resp))
         db'        (-> db
                        (assoc-in [:episodes :list]            (:episodes resp))
                        (assoc-in [:episodes :has-more?]       (:has_more resp))
                        (assoc-in [:episodes :loading?]        false)
                        (assoc-in [:episodes :restore-to-id]   nil)
                        (assoc-in [:episodes :new-episode-ids] new-ids)
                        (assoc-in [:episodes :is-premium?]     premium?)
                        (cond-> server-order
                          (assoc-in [:episodes :order] server-order))
                        (cond-> delivery
                          (assoc-in [:episodes :delivery-mode] delivery)))
         playing-id (get-in db [:audio :episode-id])
         eps        (:episodes resp)
         scroll-id  (or (when (and restore-id
                                   (some #(= (str (:id %)) restore-id) eps))
                          restore-id)
                        (when (and playing-id
                                   (some #(= (str (:id %)) (str playing-id)) eps))
                          playing-id))]
     (cond-> {:db db'}
       scroll-id (assoc ::buzz-bot.fx/scroll-to-episode scroll-id)))))
```

- [ ] **Step 2: Compile the app build**

Run: `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs compile app'`
Expected: clean.

- [ ] **Step 3: Commit**

```
git add src/cljs/buzz_bot/events.cljs
git commit -m "cljs(events): seed :delivery-mode + :new-episode-ids from /episodes response"
```

---

## Task 16 — CSS additions

Add the two new color-mix vars and all the new class rules in one focused diff.

**Files:**
- Modify: `public/css/app.css` (top of file for vars; bottom for new rules)

- [ ] **Step 1: Add the alpha-variant vars**

In `public/css/app.css`, find the `:root {` block (lines 2–25 area). After the existing `--accent-tint: color-mix(...)` line, add:

```css
  --accent-13: color-mix(in srgb, var(--button-color) 13%, transparent);
  --accent-33: color-mix(in srgb, var(--button-color) 33%, transparent);
```

- [ ] **Step 2: Add the new component rules at the bottom of the file**

Append to `public/css/app.css`:

```css
/* ── Feed delivery + sort chips ─────────────────────────────────── */

.feed-chips-row {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 0 var(--gap) 12px;
}

.delivery-chip {
  width: 140px;             /* fixed — prevents jitter on label change */
  height: 28px;
  padding: 5px 12px 5px 10px;
  border-radius: 999px;
  font: 600 12.5px/1 inherit;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  white-space: nowrap;
  cursor: pointer;
  border: 1px solid var(--border);
  background: var(--secondary-bg);
  color: var(--hint-color);
  user-select: none;
  -webkit-user-select: none;
  -webkit-tap-highlight-color: transparent;
  transition: opacity 0.12s;
}
.delivery-chip:active { opacity: 0.7; }
.delivery-chip--active {
  background: var(--accent-13);
  color:      var(--button-color);
  border-color: var(--accent-33);
}
.delivery-chip__chevron { opacity: 0.6; display: inline-flex; }

.sort-chip {
  height: 28px;
  padding: 5px 10px;
  border-radius: 999px;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--hint-color);
  font: 500 12.5px/1 inherit;
  display: inline-flex;
  align-items: center;
  gap: 5px;
  cursor: pointer;
  white-space: nowrap;
  user-select: none;
}
.sort-chip:active { opacity: 0.7; }

/* ── NEW badge on episode cards ─────────────────────────────────── */

.episode-new-badge {
  display: inline-block;
  background: var(--button-color);
  color: var(--button-text-color);
  font: 700 9px/1 inherit;
  letter-spacing: 0.4px;
  padding: 1px 5px;
  border-radius: 4px;
  margin-right: 6px;
  text-transform: uppercase;
  flex: 0 0 auto;
  vertical-align: middle;
}

/* ── ⋯ overflow menu (per-feed header) ──────────────────────────── */

.overflow-anchor { position: relative; display: inline-block; }
.overflow-trigger {
  background: transparent;
  border: none;
  color: var(--text-color);
  font-size: 20px;
  line-height: 1;
  padding: 4px 6px;
  cursor: pointer;
}
.overflow-trigger:active { opacity: 0.6; }
.overflow-menu {
  position: absolute;
  top: 100%;
  right: 0;
  min-width: 180px;
  background: var(--secondary-bg);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.18);
  z-index: 50;
  padding: 4px 0;
}
.overflow-menu__item {
  display: block;
  width: 100%;
  text-align: left;
  background: transparent;
  border: none;
  color: var(--text-color);
  font: 500 14px/1 inherit;
  padding: 10px 14px;
  cursor: pointer;
}
.overflow-menu__item:active { background: var(--overlay); }
.overflow-menu__item + .overflow-menu__item {
  border-top: 1px solid var(--border-lt);
}

/* ── Delivery upsell banner ─────────────────────────────────────── */

/* Mirrors the player's .send-result.upsell visual treatment for
   consistency. Appears under the chips row when a non-premium user
   tries to enable mp3 delivery. Tap-to-dismiss. */
.delivery-upsell {
  margin: 0 var(--gap) 12px;
  padding: 10px 12px;
  background: var(--accent-13);
  border: 1px solid var(--accent-33);
  border-radius: var(--radius);
  color: var(--text-color);
  font: 500 13px/1.35 inherit;
  cursor: pointer;
}
.delivery-upsell strong { font-weight: 700; }
.delivery-upsell:active { opacity: 0.7; }
```

- [ ] **Step 3: Commit**

```
git add public/css/app.css
git commit -m "css: --accent-13/-33 vars + delivery/sort chip + NEW badge + overflow menu"
```

---

## Task 17 — Delivery chip Reagent component

Form-2 component with the long-press timer pattern from `views/topics.cljs`. Renders icon + label + chevron and dispatches the cycle / picker events.

**Files:**
- Create: `src/cljs/buzz_bot/views/delivery_chip.cljs`

- [ ] **Step 1: Implement the component**

```clojure
;; src/cljs/buzz_bot/views/delivery_chip.cljs
(ns buzz-bot.views.delivery-chip
  "Delivery chip + long-press mode picker. Pure presentation + dispatch —
   business logic lives in buzz-bot.delivery / buzz-bot.events."
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.delivery :as d]
            [buzz-bot.events :as events]))

;; SVG icons — ports of feed-chrome.jsx (BellIcon, BellOffIcon, MP3Icon).
;; Kept here (not in a shared icons ns) because they're only used by this chip.

(defn- bell-icon [size]
  [:svg {:width size :height size :viewBox "0 0 14 14" :fill "currentColor"}
   [:path {:d "M7 1 C5 1 4 2.5 4 4.5 C4 7 3 8 2 9 H12 C11 8 10 7 10 4.5 C10 2.5 9 1 7 1 Z"}]
   [:path {:d "M5.5 10.5 C5.5 11.5 6.2 12 7 12 C7.8 12 8.5 11.5 8.5 10.5 Z"}]])

(defn- bell-off-icon [size]
  [:svg {:width size :height size :viewBox "0 0 14 14" :fill "none"}
   [:path {:d "M7 1.5 C5.3 1.5 4.4 2.7 4.4 4.5 C4.4 7 3.5 8 2.7 8.8 H11.3 C10.5 8 9.6 7 9.6 4.5 C9.6 2.7 8.7 1.5 7 1.5 Z"
           :stroke "currentColor" :stroke-width "1.2" :stroke-linejoin "round"}]
   [:path {:d "M1.5 1.5 L12.5 12.5" :stroke "currentColor" :stroke-width "1.4" :stroke-linecap "round"}]])

(defn- mp3-icon [size]
  [:svg {:width size :height size :viewBox "0 0 14 14" :fill "none"}
   [:path {:d "M3 1.5 H8 L11 4.5 V12 C11 12.3 10.8 12.5 10.5 12.5 H3 C2.7 12.5 2.5 12.3 2.5 12 V2 C2.5 1.7 2.7 1.5 3 1.5 Z"
           :stroke "currentColor" :stroke-width "1.2" :stroke-linejoin "round"}]
   [:path {:d "M8 1.5 V4.5 H11" :stroke "currentColor" :stroke-width "1.2" :stroke-linejoin "round"}]
   [:text {:x "7" :y "10.3" :text-anchor "middle"
           :font-size "3.2" :font-weight "700"
           :fill "currentColor"} "MP3"]])

(defn- chevron-down [size]
  [:svg {:width size :height size :viewBox "0 0 12 12" :fill "none"}
   [:path {:d "M2 4 L6 8 L10 4" :stroke "currentColor" :stroke-width "1.6"
           :stroke-linecap "round" :stroke-linejoin "round"}]])

(defn- icon-for [mode]
  (case (d/mode->icon-key mode)
    :bell     [bell-icon 13]
    :bell-off [bell-off-icon 13]
    :mp3      [mp3-icon 13]))

;; Mode picker — prefer Telegram.WebApp.showPopup (native sheet); fall back
;; to window.confirm-style sequential prompt when SDK doesn't expose it.
;; The mp3 button is labeled "(Premium)" for non-premium users; the
;; ::set-delivery-mode handler enforces the gate (no PATCH; banner instead).
(defn- open-picker! [feed-id current-mode premium?]
  (let [tg     (some-> js/window .-Telegram .-WebApp)
        popup? (and tg (.-showPopup tg))
        mp3-label (if premium? "Send MP3" "Send MP3 (Premium)")]
    (if popup?
      (.showPopup tg
        #js{:title   "Delivery for this feed"
            :message (str "Pick how new episodes reach you:\n"
                          "• In-app only — New episodes appear here. We won't ping you.\n"
                          "• Notify me — Telegram message when a new episode drops. Tap to play.\n"
                          "• Send MP3 — The audio file lands in your Telegram chat. Listen anywhere.")
            :buttons #js[#js{:id "off"    :type "default" :text "In-app only"}
                         #js{:id "notify" :type "default" :text "Notify me"}
                         #js{:id "mp3"    :type "default" :text mp3-label}]}
        (fn [chosen-id]
          (when (and chosen-id (not= chosen-id (name current-mode)))
            (rf/dispatch [::events/set-delivery-mode feed-id (keyword chosen-id)]))))
      ;; Fallback — desktop / older WebViews
      (let [next-m (cond
                     (and premium? (js/confirm "Send MP3 to chat for new episodes?")) :mp3
                     (js/confirm "Notify in Telegram when a new episode drops?") :notify
                     :else :off)]
        (when (not= next-m current-mode)
          (rf/dispatch [::events/set-delivery-mode feed-id next-m]))))))

(defn delivery-chip
  "Reagent form-2 — outer accepts (and discards) the args Reagent passes at
   mount; inner re-binds them per render. Long-press = 500 ms; identical
   threshold to views/topics.cljs hide-topic gesture.

   Args (inner): feed-id, mode (keyword), premium? (bool). The premium flag
   gates the long-press popup's mp3 label and the cycle's next-mode (the
   cycle is computed in ::cycle-delivery-mode using db's :is-premium?)."
  [_initial-feed-id _initial-mode _initial-premium?]
  (let [timer        (r/atom nil)
        long-pressed (r/atom false)
        cancel!      (fn []
                       (when @timer (js/clearTimeout @timer) (reset! timer nil)))]
    (fn [feed-id mode premium?]
      (let [active? (not= mode :off)]
        [:button.delivery-chip
         {:class             (when active? "delivery-chip--active")
          :on-context-menu   (fn [e]
                               (.preventDefault e)
                               (reset! long-pressed true)
                               (open-picker! feed-id mode premium?))
          :on-pointer-down   (fn [_]
                               (reset! long-pressed false)
                               (reset! timer
                                       (js/setTimeout
                                        (fn []
                                          (reset! timer nil)
                                          (reset! long-pressed true)
                                          (open-picker! feed-id mode premium?))
                                        500)))
          :on-pointer-up     cancel!
          :on-pointer-leave  cancel!
          :on-pointer-cancel cancel!
          :on-click          (fn [e]
                               (.stopPropagation e)
                               (when-not @long-pressed
                                 (rf/dispatch [::events/cycle-delivery-mode feed-id])))}
         (icon-for mode)
         [:span (d/mode->label mode)]
         [:span.delivery-chip__chevron (chevron-down 9)]]))))
```

- [ ] **Step 2: Compile**

Run: `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs compile app'`
Expected: clean.

- [ ] **Step 3: Commit**

```
git add src/cljs/buzz_bot/views/delivery_chip.cljs
git commit -m "cljs(views): delivery-chip — icon + label + chevron, tap-cycle + long-press picker"
```

---

## Task 18 — Episodes view: header + chips row + overflow menu + NEW badge + mark-viewed

The substantive UI change. Replaces the existing two-row header in `views/episodes.cljs` with a single-row header, adds the chips row underneath, the `⋯` overflow menu, the NEW-badge wiring inside the episode item, and fires `::mark-feed-viewed` on mount.

**Files:**
- Modify: `src/cljs/buzz_bot/views/episodes.cljs`

- [ ] **Step 1: Rewrite the view**

Replace the file's content with:

```clojure
(ns buzz-bot.views.episodes
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]
            [buzz-bot.delivery :as d]
            [buzz-bot.views.delivery-chip :refer [delivery-chip]]
            [buzz-bot.views.utils :refer [img-proxy]]))

(defn- fmt-pub-date [published-at]
  (when published-at
    (let [d      (js/Date. published-at)
          months #js ["Jan" "Feb" "Mar" "Apr" "May" "Jun"
                      "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"]]
      (str (aget months (.getMonth d)) " " (.getDate d) ", " (.getFullYear d)))))

(defn- fmt-duration [sec]
  (when (and sec (pos? sec))
    (let [h (js/Math.floor (/ sec 3600))
          m (js/Math.floor (/ (mod sec 3600) 60))]
      (if (pos? h) (str h "h " m "m") (str m " min")))))

(defn- episode-item [ep playing-id cached-ids new-ids]
  (let [date-str (fmt-pub-date (:published_at ep))
        dur-str  (fmt-duration (:duration_seconds ep))
        meta-str (cond (and date-str dur-str) (str date-str " · " dur-str)
                       date-str date-str
                       dur-str  dur-str)
        is-new?  (d/new? new-ids (:id ep))]
    [:li.episode-item
     {:class           (cond-> ""
                         (:listened ep)                        (str " listened")
                         (= (str (:id ep)) (str playing-id))  (str " is-playing")
                         (contains? cached-ids (str (:id ep))) (str " cached"))
      :data-episode-id (str (:id ep))
      :on-click        #(rf/dispatch [::events/navigate :player
                                      {:episode-id (:id ep) :from "episodes"}])}
     (when-let [img (:episode_image_url ep)]
       [:img.episode-thumb {:src      (img-proxy img)
                            :alt      ""
                            :loading  "lazy"
                            :decoding "async"
                            :width    48
                            :height   48}])
     [:div.episode-info
      [:span.episode-title
       (when is-new? [:span.episode-new-badge "New"])
       (:title ep)]
      (when meta-str [:span.episode-meta meta-str])]
     [:span.episode-play-icon "▶"]]))

(defn- overflow-menu [feed-id feed-url menu-open?]
  (when @menu-open?
    [:div.overflow-menu
     (when feed-url
       [:button.overflow-menu__item
        {:on-click (fn [_]
                     (reset! menu-open? false)
                     (rf/dispatch [::events/copy-rss-url feed-url]))}
        "Copy RSS link"])
     [:button.overflow-menu__item
      {:on-click (fn [_]
                   (reset! menu-open? false)
                   (rf/dispatch [::events/fetch-episodes feed-id]))}
      "Refresh now"]]))

(defn view []
  (let [menu-open?  (r/atom false)
        ;; Document-level click listener installed lazily on first menu open.
        ;; Stored in an atom so we can remove it on unmount / next close.
        outside-fn  (atom nil)
        unmount!    (fn []
                      (when-let [f @outside-fn]
                        (.removeEventListener js/document "click" f true)
                        (reset! outside-fn nil)))
        toggle-menu! (fn []
                       (swap! menu-open? not)
                       (if @menu-open?
                         (let [f (fn [_] (reset! menu-open? false) (unmount!))]
                           (reset! outside-fn f)
                           (.addEventListener js/document "click" f true))
                         (unmount!)))]
    (r/create-class
     {:component-will-unmount unmount!
      :reagent-render
      (fn []
        (let [episodes        @(rf/subscribe [::subs/episodes-list])
              loading?        @(rf/subscribe [::subs/episodes-loading?])
              has-more?       @(rf/subscribe [::subs/episodes-has-more?])
              order           @(rf/subscribe [::subs/episodes-order])
              playing-id      @(rf/subscribe [::subs/audio-episode-id])
              cached-ids      @(rf/subscribe [::subs/cached-ids])
              delivery-mode   @(rf/subscribe [::subs/delivery-mode])
              premium?        @(rf/subscribe [::subs/is-premium?])
              upsell?         @(rf/subscribe [::subs/delivery-upsell?])
              new-ids         @(rf/subscribe [::subs/new-episode-ids])
              {:keys [feed-id feed-url feed-title]} @(rf/subscribe [:buzz-bot.subs/view-params])]

          ;; Fire-and-forget mark-viewed on first render with episodes loaded
          ;; (the marker happens after the badges have rendered).
          (r/with-let [_ (when (and feed-id (seq episodes))
                           (js/setTimeout
                            #(rf/dispatch [::events/mark-feed-viewed feed-id])
                            100))])

          [:div.episodes-container
           ;; ── Header — one row ──
           [:div.section-header
            [:div.section-header-row
             [:button.btn-back
              {:on-click #(rf/dispatch [::events/navigate :feeds])}
              "← Feeds"]
             (when feed-title
               [:span.section-feed-title feed-title])
             [:span {:style {:flex 1}}]
             [:span.overflow-anchor
              {:on-click #(.stopPropagation %)}  ; keep menu open until next outside click
              [:button.overflow-trigger {:on-click toggle-menu!} "⋯"]
              [overflow-menu feed-id feed-url menu-open?]]]]

           ;; ── Chips row ──
           (when feed-id
             [:div.feed-chips-row
              [delivery-chip feed-id delivery-mode premium?]
              [:button.sort-chip
               {:on-click #(rf/dispatch [::events/set-order (if (= order :asc) :desc :asc)])}
               [:span (if (= order :asc) "↑" "↕")]
               (if (= order :asc) "Oldest" "Newest")]])

           ;; ── Upsell banner — non-premium tried mp3 ──
           (when upsell?
             [:div.delivery-upsell
              {:on-click #(rf/dispatch [::events/dismiss-delivery-upsell])}
              "⭐ " [:strong "Premium feature."]
              " Auto-deliver MP3s to your Telegram chat with a Buzz-Bot subscription."])

           ;; ── Body ──
           (cond
             (and loading? (empty? episodes)) [:div.loading "Loading..."]
             (empty? episodes)                [:div.empty-msg "No episodes in this feed."]
             :else
             [:<>
              [:ul#episode-list.episode-list
               {:data-feed-id (str feed-id)}
               (for [ep episodes]
                 ^{:key (:id ep)} [episode-item ep playing-id cached-ids new-ids])]
              (when has-more?
                [:button.btn-load-more
                 {:on-click #(rf/dispatch [::events/load-more-episodes])
                  :disabled loading?}
                 (if loading? "Loading..." "Load more")])])]))})))
```

- [ ] **Step 2: Verify the referenced subs exist**

Run: `grep -n 'reg-sub ::delivery-mode\|reg-sub ::new-episode-ids' src/cljs/buzz_bot/subs.cljs`
Expected: two matches (from Task 13).

- [ ] **Step 3: Compile**

Run: `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs compile app'`
Expected: clean — `0 warnings`.

- [ ] **Step 4: Commit**

```
git add src/cljs/buzz_bot/views/episodes.cljs
git commit -m "cljs(views/episodes): one-row header + chips row + overflow menu + NEW badge"
```

---

## Task 19 — Final release build + push

**Files:**
- Modify: `public/js/main.js` (auto-generated)

- [ ] **Step 1: Run the full test suite**

Run: `nix-shell -p jdk21_headless --run 'npm test'`
Expected: all tests pass — count includes the 6 new delivery-test deftests from Task 12.

- [ ] **Step 2: Run the Crystal specs**

Run: `nix-shell -p crystal -p shards --run 'crystal spec'`
Expected: all specs pass — includes the new specs from Tasks 4 and 5 (10 examples added).

- [ ] **Step 3: Type-check Crystal**

Run: `nix-shell -p crystal -p shards --run 'crystal build src/buzz_bot.cr --no-codegen'`
Expected: completes with no output.

- [ ] **Step 4: Build the release bundle**

Run: `nix-shell -p jdk21_headless --run 'node node_modules/.bin/shadow-cljs release app'`
Expected: `[:app] Build completed. (… files, … compiled, 0 warnings, … s)`.

- [ ] **Step 5: Commit the regenerated bundle**

```
git add -f public/js/main.js
git commit -m "build: regenerate main.js for delivery-mode feature"
git push origin main
```

Expected: push succeeds; CI/k8s/deploy.sh will pick this up.

- [ ] **Step 6: Operator smoke (post-deploy)**

After `k8s/deploy.sh`:

1. Open the Mini App → Feeds → tap a feed. Verify the header is **one row** with `← Feeds NRC Vandaag ⋯`.
2. Verify the chips row shows `🔔 In-app only ▾` (off mode default) and `↕ Newest`.
3. Tap the delivery chip — it should cycle to `Notify me`, accent-tinted background.
4. Tap again — `Send MP3`. Tap again — back to `In-app only`.
5. Long-press the chip — Telegram's native popup opens with three options + descriptions.
6. Pick `Notify me` from the popup — chip updates.
7. Tap `⋯` — menu shows *Copy RSS link* + *Refresh now*; click outside — menu dismisses.
8. Force an RSS refresh on a feed you set to `notify` — verify a Telegram card arrives with the Listen button.
9. Repeat with `mp3` — verify the MP3 lands in chat.
10. Re-open the feed page — `NEW` badges appear on recent episodes; navigate away and back — badges are gone (they cleared on mark-viewed).

---

## Self-review notes

**Spec coverage** (cross-checked against the acceptance checklist):

| Acceptance item | Task |
|---|---|
| Migration 019 with check-constraint + partial index | 1 |
| Episode.upsert returns UpsertResult | 3 |
| GET /episodes includes delivery_mode + new_episode_ids + is_premium | 10 |
| PATCH /feeds/:id/delivery_mode validates + persists | 8 |
| PATCH returns 402 when mp3 + !user.subscribed? | 8 |
| POST /feeds/:id/viewed bumps last_viewed_at | 9 |
| DeliveryDispatch.fanout called from FeedRefresher | 7 |
| Backfill filter (subscribed_at < published_at) | 5 |
| Shared MiniAppLink.episode_button helper | **3a** |
| dub_result.cr#notify_user refactored to use the helper | **3a** |
| notify-mode photo card with text fallback + helper button | 4 |
| AudioSender.send_to_user optional caption: param | **3b** |
| mp3-mode reuses AudioSender with caption | 6 |
| One-row header | 18 |
| ⋯ menu with Copy RSS + Refresh | 18 |
| Delivery chip — 140 px, icon, label, chevron, three states | 16 + 17 + 18 |
| Tap cycle skips mp3 for non-premium | 12 + 14 |
| Long-press popup labels mp3 "(Premium)" for non-premium | 17 |
| Upsell banner on non-premium mp3 attempt; dismissible | 14 + 16 + 18 |
| Tap cycles off→notify→mp3→off (premium); optimistic + rollback | 14 + 17 |
| Long-press → Telegram.WebApp.showPopup | 17 |
| Sort chip toggles Newest↔Oldest server-side | 18 |
| NEW badge gated by new_episode_ids; cleared on view | 12 + 18 |
| --accent-13/--accent-33 via color-mix; no hardcoded hex | 16 |
| Telegram.WebApp.showPopup with fallback | 17 |

**Placeholder scan:** No "TODO", "TBD", "etc.", or "similar to…" left in the plan body. Every code step shows complete code.

**Type consistency:** Confirmed identifiers used across tasks:
- `UpsertResult{episode, was_inserted}` defined Task 3; consumed Task 3 (refresher) — exact match.
- `MiniAppLink.episode_button` defined Task 3a; consumed Task 3a (dub refactor) + Task 4 (Notify formatter) — exact match.
- `AudioSender.send_to_user(..., caption:)` signature defined Task 3b; consumed Task 6 (fanout passes caption); existing `/episodes/:id/send` caller unchanged (nil default).
- `Delivery::Dispatch::{Subscriber, EpisodeRef, Target}` defined Task 5; used Task 6 — exact match.
- `UserFeed.{set_delivery_mode, get_delivery_mode, touch_viewed, last_viewed_at, delivery_subscribers_for, VALID_DELIVERY_MODES}` defined Task 2; consumed Tasks 6, 8, 9, 10 — exact match.
- `Delivery::Notify.{build_caption, send}` defined Task 4; consumed Task 6 — exact match.
- CLJS `buzz-bot.delivery/{next-mode, mode->label, mode->icon-key, new?}` defined Task 12; consumed Tasks 14, 17, 18. `next-mode` arity is `[mode premium?]` everywhere — exact match.
- CLJS event names (`::cycle-delivery-mode`, `::set-delivery-mode`, `::delivery-patch-ok`, `::delivery-patch-err`, `::dismiss-delivery-upsell`, `::mark-feed-viewed`) defined Task 14; consumed Task 17 + 18 — exact match.
- CLJS sub names (`::delivery-mode`, `::delivery-pending`, `::delivery-upsell?`, `::is-premium?`, `::new-episode-ids`) defined Task 13; consumed Task 18 — exact match.
- CSS classes (`.delivery-chip{,--active,__chevron}`, `.sort-chip`, `.episode-new-badge`, `.overflow-anchor`, `.overflow-trigger`, `.overflow-menu{,__item}`, `.feed-chips-row`, `.delivery-upsell`) defined Task 16; consumed Tasks 17 + 18 — exact match.
