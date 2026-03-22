# ClojureScript SPA Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the vanilla JS + HTMX frontend with a Re-frame/Reagent ClojureScript SPA, converting backend routes from HTML fragments to a JSON API.

**Architecture:** A Re-frame app-db holds all UI state. Custom `::http-fetch` and `::audio-cmd` effects bridge ClojureScript to `js/fetch` and a persistent `<audio>` element. Backend Crystal routes are converted to return JSON using `JSON::Serializable` structs; ECR templates are deleted at cutover.

**Tech Stack:** ClojureScript, Re-frame 1.4.3, Reagent 1.2.0, shadow-cljs 2.28.x, Crystal/Kemal (backend unchanged except JSON output)

**Spec:** `docs/superpowers/specs/2026-03-19-clojurescript-spa-rewrite-design.md`

---

### Task 1: Create branch and shadow-cljs scaffolding

**Files:**
- Create: `shadow-cljs.edn`
- Modify: `package.json`
- Create: `src/cljs/buzz_bot/core.cljs` (stub)
- Create: `src/cljs/buzz_bot/db.cljs` (stub)
- Create: `src/cljs/buzz_bot/events.cljs` (stub)
- Create: `src/cljs/buzz_bot/subs.cljs` (stub)
- Create: `src/cljs/buzz_bot/fx.cljs` (stub)
- Create: `src/cljs/buzz_bot/audio.cljs` (stub)
- Create: `src/cljs/buzz_bot/views/layout.cljs` (stub)
- Create: `src/cljs/buzz_bot/views/miniplayer.cljs` (stub)
- Create: `src/cljs/buzz_bot/views/inbox.cljs` (stub)
- Create: `src/cljs/buzz_bot/views/feeds.cljs` (stub)
- Create: `src/cljs/buzz_bot/views/episodes.cljs` (stub)
- Create: `src/cljs/buzz_bot/views/player.cljs` (stub)
- Create: `src/cljs/buzz_bot/views/bookmarks.cljs` (stub)

- [ ] **Step 1: Create the feature branch**

```bash
cd /home/watchcat/work/crystal/buzz-bot
git checkout -b feature/clojurescript-spa
```

- [ ] **Step 2: Replace `package.json` build tooling**

Replace `package.json` with:
```json
{
  "name": "buzz-bot",
  "version": "1.0.0",
  "devDependencies": {
    "shadow-cljs": "2.28.18"
  }
}
```

Run: `npm install`
Expected: `node_modules/` populated, `package-lock.json` updated.

- [ ] **Step 3: Create `shadow-cljs.edn`**

```clojure
{:source-paths ["src/cljs"]
 :dependencies [[reagent "1.2.0"]
                [re-frame "1.4.3"]]
 :builds
 {:app {:target     :browser
        :output-dir "public/js"
        :asset-path "/js"
        :modules    {:main {:init-fn buzz-bot.core/init!}}
        :devtools   {:repl-init-ns buzz-bot.core}}}}
```

- [ ] **Step 4: Create stub ClojureScript files**

`src/cljs/buzz_bot/db.cljs`:
```clojure
(ns buzz-bot.db)

(def default-db
  {:view        :inbox
   :view-params {}
   :init-data   ""
   :theme       {}
   :inbox       {:episodes [] :loading? false
                 :filters  {:hide-listened? false :compact? false :excluded-feeds #{}}}
   :feeds       {:list [] :loading? false}
   :episodes    {:feed-id nil :list [] :loading? false :order :desc :offset 0 :has-more? false}
   :player      {:data nil :loading? false}
   :bookmarks   {:list [] :loading? false :query ""}
   :audio       {:episode-id nil :title "" :artist "" :artwork ""
                 :src "" :playing? false :current-time 0 :duration 0
                 :rate 1 :autoplay? false :pending? false}})
```

`src/cljs/buzz_bot/events.cljs`:
```clojure
(ns buzz-bot.events
  (:require [re-frame.core :as rf]
            [buzz-bot.db :as db]))

(rf/reg-event-db
 ::initialize-db
 (fn [_ _] db/default-db))
```

`src/cljs/buzz_bot/subs.cljs`:
```clojure
(ns buzz-bot.subs
  (:require [re-frame.core :as rf]))

(rf/reg-sub ::view (fn [db _] (:view db)))
```

`src/cljs/buzz_bot/fx.cljs`:
```clojure
(ns buzz-bot.fx
  (:require [re-frame.core :as rf]))

;; Stubs — implemented in Task 7
(rf/reg-fx ::http-fetch (fn [_] nil))
(rf/reg-fx ::audio-cmd  (fn [_] nil))
```

`src/cljs/buzz_bot/audio.cljs`:
```clojure
(ns buzz-bot.audio)

(defn init! [] nil) ;; stub
```

`src/cljs/buzz_bot/views/layout.cljs`:
```clojure
(ns buzz-bot.views.layout)

(defn root [] [:div "Loading..."])
```

All other view stubs (`miniplayer.cljs`, `inbox.cljs`, `feeds.cljs`, `episodes.cljs`, `player.cljs`, `bookmarks.cljs`):
```clojure
(ns buzz-bot.views.VIEWNAME)
(defn view [] [:div "TODO"])
```

`src/cljs/buzz_bot/core.cljs`:
```clojure
(ns buzz-bot.core
  (:require [reagent.dom :as rdom]
            [re-frame.core :as rf]
            [buzz-bot.events :as events]
            [buzz-bot.subs]
            [buzz-bot.fx]
            [buzz-bot.audio :as audio]
            [buzz-bot.views.layout :as layout]))

(defn ^:export init! []
  (rf/dispatch-sync [::events/initialize-db])
  (audio/init!)
  (rdom/render [layout/root] (js/document.getElementById "app")))
```

- [ ] **Step 5: Verify the project compiles**

```bash
npx shadow-cljs compile app 2>&1 | tail -20
```
Expected: `Build completed` with no errors. `public/js/main.js` is created.

- [ ] **Step 6: Update `.gitignore`**

Add these lines to `.gitignore`:
```
node_modules/
.shadow-cljs/
public/js/
```

- [ ] **Step 7: Commit**

```bash
git add shadow-cljs.edn package.json package-lock.json src/cljs/ .gitignore
git commit -m "feat: add shadow-cljs scaffolding and CLJS stub files"
```

---

### Task 2: Backend JSON infrastructure — add `JSON::Serializable` to `Feed` and `UserEpisode`, create `EpisodeJson`

**Files:**
- Modify: `src/models/feed.cr`
- Modify: `src/models/episode.cr`
- Modify: `src/models/user_episode.cr`
- Create: `src/web/json_helpers.cr`

**Context:** Crystal `JSON::Serializable` on a struct serializes all `property` fields. We add it to Feed and UserEpisode. For episode lists we need an enriched struct `EpisodeJson` that combines Episode + feed info + user data — this goes in `json_helpers.cr`. Routes will import this file and build `EpisodeJson` instances by merging data from existing model methods.

- [ ] **Step 1: Add `JSON::Serializable` to `Feed`**

Open `src/models/feed.cr`. Add `include JSON::Serializable` after the `struct Feed` line. Also add `@[JSON::Field(ignore: true)]` before any internal fields that should not be serialized (e.g. `etag`, `last_modified`, `ttl_minutes`, `last_fetched_at`, `description`):

```crystal
struct Feed
  include JSON::Serializable

  property id : Int64
  property url : String
  property title : String?
  property image_url : String?

  @[JSON::Field(ignore: true)]
  property description : String?
  @[JSON::Field(ignore: true)]
  property last_fetched_at : Time?
  @[JSON::Field(ignore: true)]
  property etag : String?
  @[JSON::Field(ignore: true)]
  property last_modified : String?
  @[JSON::Field(ignore: true)]
  property ttl_minutes : Int32?
  # ... rest of struct unchanged
```

- [ ] **Step 2: Add `JSON::Serializable` to `UserEpisode`**

Open `src/models/user_episode.cr`. Add `include JSON::Serializable`. Ignore internal fields:

```crystal
struct UserEpisode
  include JSON::Serializable

  property episode_id : Int64
  property progress_seconds : Int32
  property completed : Bool
  property liked : Bool?

  @[JSON::Field(ignore: true)]
  property id : Int64
  @[JSON::Field(ignore: true)]
  property user_id : Int64
  @[JSON::Field(ignore: true)]
  property updated_at : Time
```

- [ ] **Step 3: Create `src/web/json_helpers.cr`**

This file defines the enriched episode struct used in all list responses and a helper to build it from a batch of episodes + user data:

```crystal
require "json"

module Web
  # Enriched episode for list responses (inbox, feed episode list, bookmarks).
  struct EpisodeJson
    include JSON::Serializable

    property id               : Int64
    property title            : String
    property audio_url        : String
    property description      : String?
    property published_at     : Time?
    property duration_seconds : Int32?
    property feed_id          : Int64
    property feed_title       : String
    property feed_image_url   : String?
    property listened         : Bool
    property progress_seconds : Int32
    property liked            : Bool

    def initialize(ep : Episode, feed_title : String, feed_image_url : String?,
                   ue : UserEpisode?)
      @id               = ep.id
      @title            = ep.title
      @audio_url        = ep.audio_url
      @description      = ep.description
      @published_at     = ep.published_at
      @duration_seconds = ep.duration_sec
      @feed_id          = ep.feed_id
      @feed_title       = feed_title
      @feed_image_url   = feed_image_url
      @listened         = ue.try(&.completed) || false
      @progress_seconds = ue.try(&.progress_seconds) || 0
      @liked            = ue.try(&.liked) == true
    end
  end

  # Rec item (flat struct for recommendations in player response)
  struct RecJson
    include JSON::Serializable
    property id         : Int64
    property title      : String
    property feed_id    : Int64
    property feed_title : String

    def initialize(ep : Episode, feed_title : String)
      @id         = ep.id
      @title      = ep.title
      @feed_id    = ep.feed_id
      @feed_title = feed_title
    end
  end

  # Build a batch of EpisodeJson from a list of episodes.
  # Fetches feed info and user_episode data in bulk.
  def self.build_episode_list(episodes : Array(Episode), user_id : Int64) : Array(EpisodeJson)
    return [] of EpisodeJson if episodes.empty?

    # Batch-fetch feeds
    feed_ids  = episodes.map(&.feed_id).uniq
    feeds_map = feed_ids.each_with_object({} of Int64 => Feed) do |fid, h|
      Feed.find(fid).try { |f| h[fid] = f }
    end

    # Batch-fetch user_episodes
    ep_ids = episodes.map(&.id)
    ue_map = UserEpisode.find_batch(user_id, ep_ids)

    episodes.map do |ep|
      feed = feeds_map[ep.feed_id]?
      EpisodeJson.new(
        ep,
        feed.try(&.title) || "",
        feed.try(&.image_url),
        ue_map[ep.id]?
      )
    end
  end
end
```

- [ ] **Step 4: Add `UserEpisode.find_batch` to `src/models/user_episode.cr`**

```crystal
def self.find_batch(user_id : Int64, episode_ids : Array(Int64)) : Hash(Int64, UserEpisode)
  return({} of Int64 => UserEpisode) if episode_ids.empty?
  result = {} of Int64 => UserEpisode
  placeholders = episode_ids.each_with_index.map { |_, i| "$#{i + 2}" }.join(", ")
  AppDB.pool.query_each(
    <<-SQL,
      SELECT id, user_id, episode_id, progress_seconds, completed, liked, updated_at
      FROM user_episodes
      WHERE user_id = $1 AND episode_id IN (#{placeholders})
    SQL
    user_id, *episode_ids
  ) { |rs| ue = from_rs(rs); result[ue.episode_id] = ue }
  result
end
```

- [ ] **Step 5: Require `json_helpers.cr` in `src/web/server.cr`**

Add at the top of `src/web/server.cr` (after existing requires):
```crystal
require "./json_helpers"
```

- [ ] **Step 6: Verify Crystal compiles**

```bash
cd /home/watchcat/work/crystal/buzz-bot
crystal build src/buzz_bot.cr --no-codegen 2>&1 | head -30
```
Expected: No errors.

- [ ] **Step 7: Commit**

```bash
git add src/models/feed.cr src/models/episode.cr src/models/user_episode.cr \
        src/web/json_helpers.cr src/web/server.cr
git commit -m "feat: add JSON::Serializable to models and EpisodeJson helper struct"
```

---

### Task 3: Backend — convert inbox and bookmarks routes to JSON

**Files:**
- Modify: `src/web/routes/inbox.cr`
- Modify: `src/web/routes/discover.cr`

- [ ] **Step 1: Rewrite `src/web/routes/inbox.cr`**

```crystal
require "json"

module Web::Routes::Inbox
  def self.register
    get "/inbox" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      limit    = (env.params.query["limit"]?.try(&.to_i32) || 100).clamp(1, 500)
      offset   = env.params.query["offset"]?.try(&.to_i32) || 0
      episodes = Episode.for_inbox(user.id, limit + 1, offset)
      has_more = episodes.size > limit
      episodes = episodes.first(limit) if has_more

      items = Web.build_episode_list(episodes, user.id)

      env.response.content_type = "application/json"
      {episodes: items, has_more: has_more}.to_json
    end
  end
end
```

- [ ] **Step 2: Rewrite `src/web/routes/discover.cr`**

```crystal
require "json"

module Web::Routes::Discover
  def self.register
    get "/bookmarks" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episodes = Episode.liked_for_user(user.id, 50, 0)
      items    = Web.build_episode_list(episodes, user.id)

      env.response.content_type = "application/json"
      {episodes: items, has_more: false}.to_json
    end

    get "/bookmarks/search" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      query    = env.params.query["q"]?.try(&.strip) || ""
      episodes = query.empty? ?
        Episode.liked_for_user(user.id, 50, 0) :
        Episode.search_for_user(user.id, query, 30)
      items = Web.build_episode_list(episodes, user.id)

      env.response.content_type = "application/json"
      {episodes: items}.to_json
    end
  end
end
```

- [ ] **Step 3: Verify Crystal compiles**

```bash
crystal build src/buzz_bot.cr --no-codegen 2>&1 | head -20
```
Expected: No errors.

- [ ] **Step 4: Smoke-test with curl (requires running server)**

Start the server in background: `./devrun.sh &` (or however dev server is started). Then:
```bash
# Replace INIT_DATA with a real value from a browser session, or use an env var
curl -s -H "X-Init-Data: $INIT_DATA" http://localhost:3000/inbox | python3 -m json.tool | head -30
```
Expected: JSON with `episodes` array and `has_more` bool.

- [ ] **Step 5: Commit**

```bash
git add src/web/routes/inbox.cr src/web/routes/discover.cr
git commit -m "feat: convert inbox and bookmarks routes to JSON API"
```

---

### Task 4: Backend — convert feeds routes to JSON

**Files:**
- Modify: `src/web/routes/feeds.cr`

- [ ] **Step 1: Rewrite `src/web/routes/feeds.cr`**

Replace only the in-scope handlers. Leave `post "/feeds/opml"` unchanged.

```crystal
require "json"

module Web::Routes::Feeds
  def self.register
    get "/feeds" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feeds = Feed.for_user(user.id)
      FeedRefresher.refresh_for_user(user.id)

      env.response.content_type = "application/json"
      {feeds: feeds}.to_json
    end

    post "/feeds" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      url = env.params.body["url"]?.try(&.strip)
      halt env, status_code: 400, response: %({"error":"URL required"}) unless url && !url.empty?

      begin
        parsed = RSS.fetch_and_parse(url)
        feed   = Feed.upsert(parsed.url, parsed.title, parsed.description, parsed.image_url)
        Feed.subscribe(user.id, feed.id)

        spawn do
          parsed.episodes.each do |ep|
            Episode.upsert(feed.id, ep.guid, ep.title, ep.description,
                           ep.audio_url, ep.duration_sec, ep.published_at)
          rescue ex
            Log.warn { "Episode upsert error: #{ex.message}" }
          end
        end

        env.response.content_type = "application/json"
        {feed: feed}.to_json
      rescue ex
        env.response.status_code = 422
        env.response.content_type = "application/json"
        {error: ex.message || "unknown error"}.to_json
      end
    end

    # OPML import — unchanged (deferred)
    post "/feeds/opml" do |env|
      # ... existing handler unchanged ...
    end

    post "/feeds/:id/subscribe" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feed_id = env.params.url["id"].to_i64
      Feed.subscribe(user.id, feed_id)

      feed = Feed.find(feed_id)
      env.response.content_type = "application/json"
      {feed: feed}.to_json
    end

    delete "/feeds/:id" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      feed_id = env.params.url["id"].to_i64
      Feed.unsubscribe(user.id, feed_id)

      env.response.status_code = 204
      nil
    end
  end
end
```

**Note:** When editing this file, preserve the full `post "/feeds/opml"` block as-is — do not delete it. Replace only the other handlers.

- [ ] **Step 2: Verify Crystal compiles**

```bash
crystal build src/buzz_bot.cr --no-codegen 2>&1 | head -20
```

- [ ] **Step 3: Commit**

```bash
git add src/web/routes/feeds.cr
git commit -m "feat: convert feeds routes to JSON API"
```

---

### Task 5: Backend — convert episodes list and signal routes to JSON

**Files:**
- Modify: `src/web/routes/episodes.cr`

- [ ] **Step 1: Rewrite `GET /episodes` and `PUT /episodes/:id/signal` in `src/web/routes/episodes.cr`**

Replace only the two handlers (`get "/episodes"` and `put "/episodes/:id/signal"`). Leave all other handlers unchanged (`GET /episodes/:id/player`, `PUT /episodes/:id/progress`, `POST /episodes/:id/send`, `GET /episodes/:id/audio_proxy`).

New `get "/episodes"`:
```crystal
get "/episodes" do |env|
  user = Auth.current_user(env)
  halt env, status_code: 401, response: "Unauthorized" unless user

  feed_id = env.params.query["feed_id"]?.try(&.to_i64)
  halt env, status_code: 400, response: %({"error":"feed_id required"}) unless feed_id

  feed = Feed.find(feed_id)
  halt env, status_code: 404, response: %({"error":"Feed not found"}) unless feed

  limit    = (env.params.query["limit"]?.try(&.to_i32) || 50).clamp(1, 500)
  offset   = env.params.query["offset"]?.try(&.to_i32) || 0
  order    = env.params.query["order"]? == "asc" ? "asc" : "desc"
  episodes = Episode.for_feed(feed_id, limit + 1, offset, order)
  has_more = episodes.size > limit
  episodes = episodes.first(limit) if has_more

  items = Web.build_episode_list(episodes, user.id)

  env.response.content_type = "application/json"
  {episodes: items, has_more: has_more}.to_json
end
```

New `put "/episodes/:id/signal"`:
```crystal
put "/episodes/:id/signal" do |env|
  user = Auth.current_user(env)
  halt env, status_code: 401, response: "Unauthorized" unless user

  episode_id   = env.params.url["id"].to_i64
  UserEpisode.toggle_like(user.id, episode_id)
  user_episode = UserEpisode.find(user.id, episode_id)
  liked        = user_episode.try(&.liked) == true

  env.response.content_type = "application/json"
  {liked: liked}.to_json
end
```

- [ ] **Step 2: Verify Crystal compiles**

```bash
crystal build src/buzz_bot.cr --no-codegen 2>&1 | head -20
```

- [ ] **Step 3: Commit**

```bash
git add src/web/routes/episodes.cr
git commit -m "feat: convert episode list and signal routes to JSON API"
```

---

### Task 6: Backend — convert player route and add /app-spa test route

**Files:**
- Modify: `src/web/routes/episodes.cr` (player handler)
- Modify: `src/web/routes/app.cr`

- [ ] **Step 1: Rewrite `GET /episodes/:id/player` in `src/web/routes/episodes.cr`**

Replace the existing `get "/episodes/:id/player"` handler:

```crystal
get "/episodes/:id/player" do |env|
  user = Auth.current_user(env)
  halt env, status_code: 401, response: "Unauthorized" unless user

  episode_id   = env.params.url["id"].to_i64
  episode      = Episode.find(episode_id)
  halt env, status_code: 404, response: %({"error":"Episode not found"}) unless episode

  feed          = Feed.find(episode.feed_id)
  user_episode  = UserEpisode.find(user.id, episode_id)
  order         = env.params.query["order"]? == "asc" ? "asc" : "desc"
  next_id       = Episode.next_in_feed(episode.feed_id, episode_id, order)
  is_subscribed = Feed.subscribed?(user.id, episode.feed_id)
  is_premium    = user.subscribed?
  recs_raw      = Episode.recommended_for_episode(episode_id)

  rec_feeds_map = recs_raw.map(&.feed_id).uniq.each_with_object({} of Int64 => String) do |fid, h|
    h[fid] = Feed.find(fid).try(&.title) || ""
  end
  recs = recs_raw.map { |r| Web::RecJson.new(r, rec_feeds_map[r.feed_id]? || "") }

  # Build episode object with feed info (no user data needed here — user_episode returned separately)
  ep_json = Web::EpisodeJson.new(
    episode,
    feed.try(&.title) || "",
    feed.try(&.image_url),
    user_episode
  )

  env.response.content_type = "application/json"
  {
    episode:      ep_json,
    feed:         feed,
    user_episode: user_episode,
    next_id:      next_id,
    recs:         recs,
    is_subscribed: is_subscribed,
    is_premium:    is_premium,
  }.to_json
end
```

- [ ] **Step 2: Add `/app-spa` test route to `src/web/routes/app.cr`**

Open `src/web/routes/app.cr` and add after the existing `GET /app` route:

```crystal
# Temporary test route for the SPA — serves the new HTML shell
# Remove at cutover when GET /app is updated
get "/app-spa" do |env|
  bot_username = BotClient.username
  assets_version = Assets::VERSION
  env.response.content_type = "text/html"
  <<-HTML
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Buzz-Bot</title>
    <script src="/js/telegram-web-app.js"></script>
    <link rel="stylesheet" href="/css/app.css?v=#{assets_version}">
  </head>
  <body>
    <div id="app"></div>
    <script>window.BOT_USERNAME = '#{bot_username}';</script>
    <script src="/js/main.js?v=#{assets_version}"></script>
  </body>
  </html>
  HTML
end
```

- [ ] **Step 3: Verify Crystal compiles**

```bash
crystal build src/buzz_bot.cr --no-codegen 2>&1 | head -20
```
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add src/web/routes/episodes.cr src/web/routes/app.cr
git commit -m "feat: convert player route to JSON API and add /app-spa test route"
```

---

### Task 7: CLJS — Custom effects (fx.cljs) and subscriptions (subs.cljs)

**Files:**
- Modify: `src/cljs/buzz_bot/fx.cljs` (full implementation)
- Modify: `src/cljs/buzz_bot/subs.cljs` (full implementation)

- [ ] **Step 1: Implement `fx.cljs` — the `::http-fetch` and `::audio-cmd` effects**

```clojure
(ns buzz-bot.fx
  (:require [re-frame.core :as rf]
            [re-frame.db]
            [buzz-bot.audio :as audio]))

;; ── ::http-fetch ────────────────────────────────────────────────────────────
;; Options map:
;;   :method  — :get | :post | :put | :delete
;;   :url     — string
;;   :body    — nil | js/URLSearchParams | clj map (will be JSON-encoded)
;;   :on-ok   — event vector appended with parsed JSON response
;;   :on-err  — event vector appended with error string

(defn- method-str [m]
  (case m :get "GET" :post "POST" :put "PUT" :delete "DELETE" "GET"))

(defn- build-init [method body init-data]
  (let [headers (js-obj "X-Init-Data" init-data)
        base    (js-obj "method" (method-str method)
                        "headers" headers)]
    (when body
      (cond
        (instance? js/URLSearchParams body)
        (aset base "body" body)

        (map? body)
        (do (aset headers "Content-Type" "application/json")
            (aset base "body" (.stringify js/JSON (clj->js body))))))
    base))

(rf/reg-fx
 ::http-fetch
 (fn [{:keys [method url body on-ok on-err]}]
   (let [init-data (get @re-frame.db/app-db :init-data "")
         init      (build-init method body init-data)]
     (-> (js/fetch url init)
         (.then (fn [resp]
                  (if (.-ok resp)
                    (-> (.json resp)
                        (.then (fn [data]
                                 (rf/dispatch (conj on-ok (js->clj data :keywordize-keys true))))))
                    (rf/dispatch (conj on-err (str "HTTP " (.-status resp)))))))
         (.catch (fn [err]
                   (rf/dispatch (conj on-err (str err)))))))))

;; ── ::audio-cmd ─────────────────────────────────────────────────────────────
;; Delegates to buzz-bot.audio/execute-cmd!

(rf/reg-fx
 ::audio-cmd
 (fn [cmd] (audio/execute-cmd! cmd)))
```

- [ ] **Step 2: Implement `subs.cljs` — all subscriptions**

```clojure
(ns buzz-bot.subs
  (:require [re-frame.core :as rf]))

;; Top-level
(rf/reg-sub ::view         (fn [db _] (:view db)))
(rf/reg-sub ::view-params  (fn [db _] (:view-params db)))
(rf/reg-sub ::init-data    (fn [db _] (:init-data db)))

;; Inbox
(rf/reg-sub ::inbox        (fn [db _] (:inbox db)))
(rf/reg-sub ::inbox-episodes
  :<- [::inbox]
  (fn [inbox _] (:episodes inbox)))
(rf/reg-sub ::inbox-loading?
  :<- [::inbox]
  (fn [inbox _] (:loading? inbox)))
(rf/reg-sub ::inbox-filters
  :<- [::inbox]
  (fn [inbox _] (:filters inbox)))

;; Feeds
(rf/reg-sub ::feeds-list     (fn [db _] (get-in db [:feeds :list])))
(rf/reg-sub ::feeds-loading? (fn [db _] (get-in db [:feeds :loading?])))

;; Episodes
(rf/reg-sub ::episodes     (fn [db _] (:episodes db)))
(rf/reg-sub ::episodes-list
  :<- [::episodes]
  (fn [ep _] (:list ep)))
(rf/reg-sub ::episodes-loading?
  :<- [::episodes]
  (fn [ep _] (:loading? ep)))
(rf/reg-sub ::episodes-has-more?
  :<- [::episodes]
  (fn [ep _] (:has-more? ep)))
(rf/reg-sub ::episodes-order
  :<- [::episodes]
  (fn [ep _] (:order ep)))

;; Player
(rf/reg-sub ::player-data     (fn [db _] (get-in db [:player :data])))
(rf/reg-sub ::player-loading? (fn [db _] (get-in db [:player :loading?])))

;; Bookmarks
(rf/reg-sub ::bookmarks-list     (fn [db _] (get-in db [:bookmarks :list])))
(rf/reg-sub ::bookmarks-loading? (fn [db _] (get-in db [:bookmarks :loading?])))

;; Audio
(rf/reg-sub ::audio         (fn [db _] (:audio db)))
(rf/reg-sub ::audio-playing? :<- [::audio] (fn [a _] (:playing? a)))
(rf/reg-sub ::audio-pending? :<- [::audio] (fn [a _] (:pending? a)))
(rf/reg-sub ::audio-episode-id :<- [::audio] (fn [a _] (:episode-id a)))
(rf/reg-sub ::audio-current-time :<- [::audio] (fn [a _] (:current-time a)))
(rf/reg-sub ::audio-duration :<- [::audio] (fn [a _] (:duration a)))
(rf/reg-sub ::audio-rate :<- [::audio] (fn [a _] (:rate a)))
(rf/reg-sub ::audio-title :<- [::audio] (fn [a _] (:title a)))
(rf/reg-sub ::audio-artist :<- [::audio] (fn [a _] (:artist a)))
(rf/reg-sub ::audio-artwork :<- [::audio] (fn [a _] (:artwork a)))
```

- [ ] **Step 3: Verify compilation**

```bash
npx shadow-cljs compile app 2>&1 | tail -10
```
Expected: `Build completed`.

- [ ] **Step 4: Commit**

```bash
git add src/cljs/buzz_bot/fx.cljs src/cljs/buzz_bot/subs.cljs
git commit -m "feat: implement http-fetch/audio-cmd effects and all subscriptions"
```

---

### Task 8: CLJS — Full events implementation

**Files:**
- Modify: `src/cljs/buzz_bot/events.cljs` (full implementation)

- [ ] **Step 1: Write `events.cljs`**

```clojure
(ns buzz-bot.events
  (:require [re-frame.core :as rf]
            [clojure.string :as str]
            [buzz-bot.db :as db]
            [buzz-bot.fx]))

(rf/reg-event-db ::initialize-db (fn [_ _] db/default-db))

;; ── Navigation ───────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::navigate
 (fn [{:keys [db]} [_ view params]]
   (let [fetch-event (case view
                       :inbox     [::fetch-inbox]
                       :feeds     [::fetch-feeds]
                       :player    [::fetch-player (:episode-id params)]
                       :bookmarks [::fetch-bookmarks]
                       :episodes  [::fetch-episodes (:feed-id params)]
                       nil)]
     (cond-> {:db (assoc db :view view :view-params (or params {}))}
       fetch-event (assoc :dispatch fetch-event)))))

;; ── Inbox ────────────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-inbox
 (fn [{:keys [db]} _]
   {:db         (assoc-in db [:inbox :loading?] true)
    ::buzz-bot.fx/http-fetch {:method :get :url "/inbox"
                              :on-ok  [::inbox-loaded] :on-err [::fetch-error]}}))

(rf/reg-event-db
 ::inbox-loaded
 (fn [db [_ resp]]
   (-> db
       (assoc-in [:inbox :episodes] (:episodes resp))
       (assoc-in [:inbox :loading?] false))))

;; ── Feeds ────────────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-feeds
 (fn [{:keys [db]} _]
   {:db         (assoc-in db [:feeds :loading?] true)
    ::buzz-bot.fx/http-fetch {:method :get :url "/feeds"
                              :on-ok  [::feeds-loaded] :on-err [::fetch-error]}}))

(rf/reg-event-db
 ::feeds-loaded
 (fn [db [_ resp]]
   (-> db
       (assoc-in [:feeds :list] (:feeds resp))
       (assoc-in [:feeds :loading?] false))))

(rf/reg-event-fx
 ::subscribe-feed
 (fn [_ [_ url]]
   {::buzz-bot.fx/http-fetch {:method :post :url "/feeds"
                              :body   (js/URLSearchParams. #js{"url" url})
                              :on-ok  [::subscribe-feed-ok] :on-err [::fetch-error]}}))

(rf/reg-event-fx
 ::subscribe-feed-ok
 (fn [_ _] {:dispatch [::fetch-feeds]}))

(rf/reg-event-fx
 ::unsubscribe-feed
 (fn [_ [_ feed-id]]
   {::buzz-bot.fx/http-fetch {:method :delete :url (str "/feeds/" feed-id)
                              :on-ok  [::unsubscribe-feed-ok] :on-err [::fetch-error]}}))

(rf/reg-event-fx
 ::unsubscribe-feed-ok
 (fn [_ _] {:dispatch [::fetch-feeds]}))

;; ── Episode list ─────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-episodes
 (fn [{:keys [db]} [_ feed-id]]
   (let [order (get-in db [:episodes :order] :desc)]
     {:db         (-> db
                      (assoc-in [:episodes :feed-id]  feed-id)
                      (assoc-in [:episodes :list]     [])
                      (assoc-in [:episodes :offset]   0)
                      (assoc-in [:episodes :loading?] true))
      ::buzz-bot.fx/http-fetch {:method :get
                                :url    (str "/episodes?feed_id=" feed-id
                                             "&order=" (name order))
                                :on-ok  [::episodes-loaded] :on-err [::fetch-error]}})))

(rf/reg-event-db
 ::episodes-loaded
 (fn [db [_ resp]]
   (-> db
       (assoc-in [:episodes :list]      (:episodes resp))
       (assoc-in [:episodes :has-more?] (:has_more resp))
       (assoc-in [:episodes :loading?]  false))))

(rf/reg-event-fx
 ::load-more-episodes
 (fn [{:keys [db]} _]
   (let [{:keys [feed-id order offset list]} (:episodes db)
         new-offset (+ offset (count list))]
     {:db         (assoc-in db [:episodes :loading?] true)
      ::buzz-bot.fx/http-fetch {:method :get
                                :url    (str "/episodes?feed_id=" feed-id
                                             "&order=" (name order)
                                             "&offset=" new-offset)
                                :on-ok  [::more-episodes-loaded new-offset]
                                :on-err [::fetch-error]}})))

(rf/reg-event-db
 ::more-episodes-loaded
 (fn [db [_ _offset resp]]
   (-> db
       (update-in [:episodes :list]     into (:episodes resp))
       (assoc-in  [:episodes :has-more?] (:has_more resp))
       (assoc-in  [:episodes :loading?]  false))))

(rf/reg-event-fx
 ::set-order
 (fn [{:keys [db]} [_ order]]
   (let [feed-id (get-in db [:episodes :feed-id])]
     {:db       (assoc-in db [:episodes :order] order)
      :dispatch [::fetch-episodes feed-id]})))

;; ── Player ───────────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-player
 (fn [{:keys [db]} [_ episode-id]]
   {:db         (assoc-in db [:player :loading?] true)
    ::buzz-bot.fx/http-fetch {:method :get
                              :url    (str "/episodes/" episode-id "/player")
                              :on-ok  [::player-loaded] :on-err [::fetch-error]}}))

(rf/reg-event-fx
 ::player-loaded
 (fn [{:keys [db]} [_ resp]]
   (let [new-id    (str (get-in resp [:episode :id]))
         cur-id    (str (get-in db [:audio :episode-id]))
         playing?  (get-in db [:audio :playing?])
         episode   (get-in resp [:episode])
         db'       (-> db
                       (assoc-in [:player :data]     resp)
                       (assoc-in [:player :loading?] false)
                       (assoc-in [:audio :title]     (:title episode))
                       (assoc-in [:audio :artist]    (:feed_title episode))
                       (assoc-in [:audio :artwork]   (:feed_image_url episode)))]
     (if (and playing? (not= cur-id new-id))
       {:db db' :dispatch [::audio-queue-pending]}
       {:db db' :dispatch [::audio-load]}))))

;; ── Bookmarks ────────────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::fetch-bookmarks
 (fn [{:keys [db]} _]
   {:db         (assoc-in db [:bookmarks :loading?] true)
    ::buzz-bot.fx/http-fetch {:method :get :url "/bookmarks"
                              :on-ok  [::bookmarks-loaded] :on-err [::fetch-error]}}))

(rf/reg-event-db
 ::bookmarks-loaded
 (fn [db [_ resp]]
   (-> db
       (assoc-in [:bookmarks :list]     (:episodes resp))
       (assoc-in [:bookmarks :loading?] false))))

(rf/reg-event-fx
 ::search-bookmarks
 (fn [_ [_ query]]
   {::buzz-bot.fx/http-fetch {:method :get
                              :url    (str "/bookmarks/search?q=" (js/encodeURIComponent query))
                              :on-ok  [::bookmarks-loaded] :on-err [::fetch-error]}}))

;; ── Audio state ──────────────────────────────────────────────────────────────

(rf/reg-event-db ::audio-playing (fn [db _] (assoc-in db [:audio :playing?] true)))
(rf/reg-event-db ::audio-paused  (fn [db _] (assoc-in db [:audio :playing?] false)))
(rf/reg-event-db ::audio-tick    (fn [db [_ t]] (assoc-in db [:audio :current-time] t)))
(rf/reg-event-db ::audio-duration (fn [db [_ d]] (assoc-in db [:audio :duration] d)))

(rf/reg-event-fx
 ::audio-ended
 (fn [{:keys [db]} _]
   (let [autoplay? (get-in db [:audio :autoplay?])
         next-id   (get-in db [:player :data :next_id])]
     (when (and autoplay? next-id)
       {:dispatch [::navigate :player {:episode-id next-id}]}))))

;; ── Audio commands ───────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::audio-load
 (fn [{:keys [db]} [_ opts]]
   (let [src   (get-in db [:player :data :episode :audio_url])
         start (get-in db [:player :data :user_episode :progress_seconds] 0)
         ep-id (str (get-in db [:player :data :episode :id]))
         autoplay? (:autoplay? opts false)]
     (js/localStorage.setItem "buzz-last-episode-id" ep-id)
     (js/localStorage.setItem "buzz-last-episode-meta"
       (.stringify js/JSON
         (clj->js {:title   (get-in db [:player :data :episode :title])
                   :podcast (get-in db [:player :data :episode :feed_title])
                   :artwork (get-in db [:player :data :episode :feed_image_url])})))
     {:db         (-> db
                      (assoc-in [:audio :episode-id] ep-id)
                      (assoc-in [:audio :src]        src)
                      (assoc-in [:audio :pending?]   false))
      ::buzz-bot.fx/audio-cmd {:op :load :src src :start start :autoplay? autoplay?}})))

(rf/reg-event-db
 ::audio-queue-pending
 (fn [db _] (assoc-in db [:audio :pending?] true)))

(rf/reg-event-fx
 ::toggle-play-pause
 (fn [{:keys [db]} _]
   (cond
     (get-in db [:audio :pending?])  {:dispatch [::audio-commit-pending]}
     (get-in db [:audio :playing?])  {::buzz-bot.fx/audio-cmd {:op :pause}}
     :else                           {::buzz-bot.fx/audio-cmd {:op :play}})))

(rf/reg-event-fx
 ::audio-commit-pending
 (fn [_ _] {:dispatch [::audio-load {:autoplay? true}]}))

(rf/reg-event-fx
 ::audio-play
 (fn [_ _] {::buzz-bot.fx/audio-cmd {:op :play}}))

(rf/reg-event-fx
 ::audio-pause
 (fn [_ _] {::buzz-bot.fx/audio-cmd {:op :pause}}))

(rf/reg-event-fx
 ::audio-seek
 (fn [_ [_ t]] {::buzz-bot.fx/audio-cmd {:op :seek :time t}}))

(rf/reg-event-fx
 ::audio-seek-relative
 (fn [_ [_ d]] {::buzz-bot.fx/audio-cmd {:op :seek-relative :delta d}}))

(rf/reg-event-fx
 ::cycle-speed
 (fn [{:keys [db]} _]
   (let [rates [1 1.5 2]
         cur   (get-in db [:audio :rate] 1)
         idx   (.indexOf (clj->js rates) cur)
         next  (get rates (mod (inc idx) (count rates)) 1)]
     (js/localStorage.setItem "buzz-playback-speed" (str next))
     {:db (assoc-in db [:audio :rate] next)
      ::buzz-bot.fx/audio-cmd {:op :set-rate :rate next}})))

;; ── Player actions ───────────────────────────────────────────────────────────

(rf/reg-event-fx
 ::toggle-bookmark
 (fn [{:keys [db]} [_ episode-id]]
   {::buzz-bot.fx/http-fetch {:method :put
                              :url    (str "/episodes/" episode-id "/signal")
                              :on-ok  [::bookmark-toggled] :on-err [::fetch-error]}}))

(rf/reg-event-db
 ::bookmark-toggled
 (fn [db [_ resp]]
   (assoc-in db [:player :data :user_episode :liked] (:liked resp))))

(rf/reg-event-db
 ::toggle-autoplay
 (fn [db _]
   (let [new-val (not (get-in db [:audio :autoplay?]))]
     (js/localStorage.setItem "buzz-autoplay" (str new-val))
     (assoc-in db [:audio :autoplay?] new-val))))

(rf/reg-event-fx
 ::subscribe-from-player
 (fn [{:keys [db]} [_ feed-id]]
   {::buzz-bot.fx/http-fetch {:method :post :url (str "/feeds/" feed-id "/subscribe")
                              :on-ok  [::subscribe-from-player-ok] :on-err [::fetch-error]}}))

(rf/reg-event-db
 ::subscribe-from-player-ok
 (fn [db _] (assoc-in db [:player :data :is_subscribed] true)))

(rf/reg-event-fx
 ::save-progress
 (fn [{:keys [db]} [_ episode-id seconds]]
   (let [duration  (get-in db [:audio :duration] 0)
         completed (and (pos? duration) (> seconds (- duration 30)))]
     {::buzz-bot.fx/http-fetch {:method :put
                                :url    (str "/episodes/" episode-id "/progress")
                                :body   {:seconds seconds :completed completed}
                                :on-ok  [::progress-saved] :on-err [::fetch-error]}})))

(rf/reg-event-db ::progress-saved (fn [db _] db))

;; ── Filters ──────────────────────────────────────────────────────────────────

(rf/reg-event-db
 ::toggle-hide-listened
 (fn [db _]
   (update-in db [:inbox :filters :hide-listened?] not)))

(rf/reg-event-db
 ::toggle-feed-filter
 (fn [db [_ feed-id]]
   (let [excluded (get-in db [:inbox :filters :excluded-feeds] #{})]
     (assoc-in db [:inbox :filters :excluded-feeds]
               (if (contains? excluded feed-id)
                 (disj excluded feed-id)
                 (conj excluded feed-id))))))

(rf/reg-event-db
 ::toggle-compact
 (fn [db _]
   (update-in db [:inbox :filters :compact?] not)))

;; ── Error handling ───────────────────────────────────────────────────────────

(rf/reg-event-db
 ::fetch-error
 (fn [db [_ err]]
   (js/console.error "Fetch error:" err)
   db))
```

- [ ] **Step 2: Verify compilation**

```bash
npx shadow-cljs compile app 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add src/cljs/buzz_bot/events.cljs
git commit -m "feat: implement all Re-frame events"
```

---

### Task 9: CLJS — Audio interop layer

**Files:**
- Modify: `src/cljs/buzz_bot/audio.cljs` (full implementation)

- [ ] **Step 1: Implement `audio.cljs`**

```clojure
(ns buzz-bot.audio
  (:require [re-frame.core :as rf]
            [re-frame.db]))

(defonce audio-el (js/Audio.))

(set! (.-preload audio-el) "metadata")
(.appendChild js/document.body audio-el)

;; rAF throttle for timeupdate
(defonce raf-pending? (atom false))

(defn- on-timeupdate []
  (when-not @raf-pending?
    (reset! raf-pending? true)
    (js/requestAnimationFrame
     (fn []
       (reset! raf-pending? false)
       (rf/dispatch-sync [:buzz-bot.events/audio-tick (.-currentTime audio-el)])))))

(defn- wire-listeners! []
  (.addEventListener audio-el "timeupdate"    on-timeupdate)
  (.addEventListener audio-el "durationchange"
    (fn [] (rf/dispatch [:buzz-bot.events/audio-duration (.-duration audio-el)])))
  (.addEventListener audio-el "play"
    (fn [] (rf/dispatch [:buzz-bot.events/audio-playing])))
  (.addEventListener audio-el "pause"
    (fn [] (rf/dispatch [:buzz-bot.events/audio-paused])))
  (.addEventListener audio-el "ended"
    (fn [] (rf/dispatch [:buzz-bot.events/audio-ended]))))

(defn- wire-media-session! []
  (when (.. js/navigator -mediaSession)
    (let [ms (.. js/navigator -mediaSession)]
      (.setActionHandler ms "play"         #(.play audio-el))
      (.setActionHandler ms "pause"        #(.pause audio-el))
      (.setActionHandler ms "seekbackward" #(set! (.-currentTime audio-el)
                                                  (max 0 (- (.-currentTime audio-el) 10))))
      (.setActionHandler ms "seekforward"  #(set! (.-currentTime audio-el)
                                                  (+ (.-currentTime audio-el) 30))))))

(defn- start-progress-interval! []
  (js/setInterval
   (fn []
     (when-not (.-paused audio-el)
       (let [ep-id (get-in @re-frame.db/app-db [:audio :episode-id])]
         (when ep-id
           (rf/dispatch [:buzz-bot.events/save-progress ep-id
                         (js/Math.floor (.-currentTime audio-el))])))))
   5000))

(defn init! []
  (wire-listeners!)
  (wire-media-session!)
  (start-progress-interval!))

;; ── Command dispatch ─────────────────────────────────────────────────────────

(defmulti execute-cmd! :op)

(defmethod execute-cmd! :load [{:keys [src start autoplay?]}]
  (set! (.-src audio-el) src)
  (set! (.. audio-el -dataset -episodeId) "")  ; cleared until loaded
  (.load audio-el)
  (.addEventListener audio-el "loadedmetadata"
    (fn []
      (when (pos? start)
        (set! (.-currentTime audio-el) start))
      (set! (.-playbackRate audio-el) (or (.-playbackRate audio-el) 1))
      (when autoplay?
        (-> (.play audio-el) (.catch (fn [])))))
    #js{:once true}))

(defmethod execute-cmd! :play [_]
  (-> (.play audio-el) (.catch (fn []))))

(defmethod execute-cmd! :pause [_]
  (.pause audio-el))

(defmethod execute-cmd! :seek [{:keys [time]}]
  (set! (.-currentTime audio-el) (max 0 (min (or (.-duration audio-el) 0) time))))

(defmethod execute-cmd! :seek-relative [{:keys [delta]}]
  (set! (.-currentTime audio-el)
        (max 0 (min (or (.-duration audio-el) 0)
                    (+ (.-currentTime audio-el) delta)))))

(defmethod execute-cmd! :set-rate [{:keys [rate]}]
  (set! (.-playbackRate audio-el) rate))

(defmethod execute-cmd! :default [cmd]
  (js/console.warn "Unknown audio-cmd:" (clj->js cmd)))
```

- [ ] **Step 2: Verify compilation**

```bash
npx shadow-cljs compile app 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add src/cljs/buzz_bot/audio.cljs
git commit -m "feat: implement audio interop layer with MediaSession and progress interval"
```

---

### Task 10: CLJS — core.cljs and layout view

**Files:**
- Modify: `src/cljs/buzz_bot/core.cljs` (full implementation)
- Modify: `src/cljs/buzz_bot/views/layout.cljs` (full implementation)

- [ ] **Step 1: Implement `core.cljs`**

```clojure
(ns buzz-bot.core
  (:require [reagent.dom :as rdom]
            [re-frame.core :as rf]
            [clojure.string :as str]
            [buzz-bot.events :as events]
            [buzz-bot.subs]
            [buzz-bot.fx]
            [buzz-bot.audio :as audio]
            [buzz-bot.views.layout :as layout]))

(defn- tg [] (.. js/window -Telegram -WebApp))

(defn- apply-theme! []
  (when-let [params (.. (tg) -themeParams)]
    (let [root (.-style js/document.documentElement)
          p    (js->clj params)]
      (doseq [[k v] {"--bg-color"         (get p "bg_color")
                     "--text-color"       (get p "text_color")
                     "--hint-color"       (get p "hint_color")
                     "--link-color"       (get p "link_color")
                     "--button-color"     (get p "button_color")
                     "--button-text-color" (get p "button_text_color")
                     "--secondary-bg"     (get p "secondary_bg_color")}]
        (when v (.setProperty root k v))))))

(defn- check-deep-link []
  (let [start    (.. (tg) -initDataUnsafe -start_param)
        url-ep   (-> js/window .-location .-search js/URLSearchParams. (.get "episode"))
        ep-id    (or url-ep
                     (when (str/starts-with? (str start) "ep_")
                       (subs start 3)))]
    (if ep-id
      (rf/dispatch [::events/navigate :player {:episode-id ep-id}])
      (rf/dispatch [::events/navigate :inbox]))))

(defn- restore-audio-state! []
  (let [ep-id (js/localStorage.getItem "buzz-last-episode-id")
        meta  (try (-> (js/localStorage.getItem "buzz-last-episode-meta")
                       js/JSON.parse
                       (js->clj :keywordize-keys true))
                   (catch :default _ {}))
        rate  (or (js/parseFloat (js/localStorage.getItem "buzz-playback-speed")) 1)
        auto? (= "true" (js/localStorage.getItem "buzz-autoplay"))]
    (when ep-id
      (rf/dispatch-sync [::events/init-audio-meta ep-id meta rate auto?]))))

(defn- show-already-open! []
  (let [div (js/document.createElement "div")]
    (set! (.-className div) "single-instance-overlay")
    (set! (.-innerHTML div)
      (str "<div class=\"single-instance-msg\">"
           "<div class=\"single-instance-icon\">📻</div>"
           "<strong>Already open</strong>"
           "<p>Buzz-Bot is already running in another window.</p>"
           "</div>"))
    (.appendChild js/document.body div)))

(defn- mount! []
  (.ready (tg))
  (.expand (tg))
  (apply-theme!)
  (rf/dispatch-sync [::events/initialize-db])
  (rf/dispatch-sync [::events/set-init-data (.. (tg) -initData)])
  (restore-audio-state!)
  (audio/init!)
  (check-deep-link)
  (rdom/render [layout/root] (js/document.getElementById "app")))

(defn ^:export init! []
  (if-let [locks (.. js/navigator -locks)]
    (.request locks "buzz-bot-instance"
      #js{:ifAvailable true}
      (fn [lock]
        (if lock
          (do (mount!) (js/Promise. (fn [_ _])))
          (show-already-open!))))
    (mount!)))
```

- [ ] **Step 2: Add two missing events to `events.cljs`**

Add at the bottom of `src/cljs/buzz_bot/events.cljs`:

```clojure
(rf/reg-event-db
 ::set-init-data
 (fn [db [_ v]] (assoc db :init-data v)))

(rf/reg-event-db
 ::init-audio-meta
 (fn [db [_ ep-id meta rate auto?]]
   (-> db
       (assoc-in [:audio :episode-id] ep-id)
       (assoc-in [:audio :title]     (:title meta ""))
       (assoc-in [:audio :artist]    (:podcast meta ""))
       (assoc-in [:audio :artwork]   (:artwork meta ""))
       (assoc-in [:audio :rate]      rate)
       (assoc-in [:audio :autoplay?] auto?))))
```

- [ ] **Step 3: Implement `views/layout.cljs`**

```clojure
(ns buzz-bot.views.layout
  (:require [re-frame.core :as rf]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]
            [buzz-bot.views.miniplayer :as miniplayer]
            [buzz-bot.views.inbox :as inbox]
            [buzz-bot.views.feeds :as feeds]
            [buzz-bot.views.episodes :as episodes]
            [buzz-bot.views.player :as player]
            [buzz-bot.views.bookmarks :as bookmarks]))

(defn- tab-btn [label view-kw current-view]
  [:button.tab-btn
   {:class    (when (= current-view view-kw) "active")
    :on-click #(rf/dispatch [::events/navigate view-kw])}
   label])

(defn root []
  (let [view @(rf/subscribe [::subs/view])]
    [:div#app
     [:div.app-container
      [:nav.tab-bar
       [tab-btn "📥 Inbox"     :inbox     view]
       [tab-btn "📻 Feeds"     :feeds     view]
       [tab-btn "🔖 Bookmarks" :bookmarks view]]
      [:main#content
       (case view
         :inbox     [inbox/view]
         :feeds     [feeds/view]
         :episodes  [episodes/view]
         :player    [player/view]
         :bookmarks [bookmarks/view]
         [:div.loading "Loading..."])]]
     [miniplayer/bar]]))
```

- [ ] **Step 4: Verify compilation and open `/app-spa` in browser**

```bash
npx shadow-cljs watch app &
```
Start the Crystal server and open `http://localhost:3000/app-spa`. Expected: Page renders "Loading..." text, no JS errors in console.

- [ ] **Step 5: Commit**

```bash
git add src/cljs/buzz_bot/core.cljs src/cljs/buzz_bot/events.cljs src/cljs/buzz_bot/views/layout.cljs
git commit -m "feat: implement core init, Telegram SDK wiring, and layout shell"
```

---

### Task 11: CLJS — Miniplayer and Inbox views

**Files:**
- Modify: `src/cljs/buzz_bot/views/miniplayer.cljs`
- Modify: `src/cljs/buzz_bot/views/inbox.cljs`

- [ ] **Step 1: Implement `views/miniplayer.cljs`**

```clojure
(ns buzz-bot.views.miniplayer
  (:require [re-frame.core :as rf]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn bar []
  (let [ep-id    @(rf/subscribe [::subs/audio-episode-id])
        title    @(rf/subscribe [::subs/audio-title])
        artist   @(rf/subscribe [::subs/audio-artist])
        artwork  @(rf/subscribe [::subs/audio-artwork])
        playing? @(rf/subscribe [::subs/audio-playing?])
        rate     @(rf/subscribe [::subs/audio-rate])]
    (when ep-id
      [:div.now-playing-bar
       [:div.now-playing-inner
        {:on-click #(rf/dispatch [::events/navigate :player {:episode-id ep-id}])}
        [:div.now-playing-artwork
         (when artwork {:style {:background-image (str "url('" artwork "')")}})
         (when-not artwork "🎙")]
        [:div.now-playing-text
         [:span.now-playing-title  title]
         [:span.now-playing-podcast artist]]]
       [:button.btn-speed
        {:class    (when (not= rate 1) "btn-speed--active")
         :on-click #(rf/dispatch [::events/cycle-speed])}
        (if (= rate 1) "1×" (str rate "×"))]
       [:button.now-playing-playpause
        {:on-click #(rf/dispatch [::events/toggle-play-pause])}
        (if playing? "⏸" "▶")]])))
```

- [ ] **Step 2: Implement `views/inbox.cljs`**

```clojure
(ns buzz-bot.views.inbox
  (:require [re-frame.core :as rf]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- episode-visible? [ep filters]
  (let [{:keys [hide-listened? excluded-feeds compact?]} filters]
    (and (not (and hide-listened? (:listened ep)))
         (not (contains? excluded-feeds (str (:feed_id ep)))))))

(defn- episode-item [ep]
  [:li.episode-item
   {:class       (when (:listened ep) "listened")
    :data-episode-id (str (:id ep))
    :data-feed-id    (str (:feed_id ep))
    :on-click    #(rf/dispatch [::events/navigate :player {:episode-id (:id ep)}])}
   [:div.episode-info
    (when (:feed_image_url ep)
      [:div.episode-artwork {:style {:background-image (str "url('" (:feed_image_url ep) "')")}}])
    [:div.episode-text
     [:span.episode-feed  (:feed_title ep)]
     [:span.episode-title (:title ep)]]]
   [:span.episode-play "▶"]])

(defn view []
  (let [episodes  @(rf/subscribe [::subs/inbox-episodes])
        loading?  @(rf/subscribe [::subs/inbox-loading?])
        filters   @(rf/subscribe [::subs/inbox-filters])
        {:keys [hide-listened? compact? excluded-feeds]} filters
        visible   (filter #(episode-visible? % filters) episodes)]
    [:div.inbox-container
     [:div.inbox-header
      [:h2 "Inbox"]
      [:div.inbox-filters
       [:label.filter-label
        [:input.filter-checkbox
         {:type      "checkbox"
          :checked   hide-listened?
          :on-change #(rf/dispatch [::events/toggle-hide-listened])}]
        [:span.filter-switch]
        [:span "Hide listened"]]
       [:label.filter-label
        [:input.filter-checkbox
         {:type      "checkbox"
          :checked   compact?
          :on-change #(rf/dispatch [::events/toggle-compact])}]
        [:span.filter-switch]
        [:span "Compact"]]]]
     (cond
       loading?        [:div.loading "Loading..."]
       (empty? visible) [:div.empty-msg "No episodes. Subscribe to some feeds!"]
       :else
       [:ul.episode-list#episode-list
        (for [ep visible]
          ^{:key (:id ep)} [episode-item ep])])]))
```

- [ ] **Step 3: Open `/app-spa` and verify inbox loads**

Dispatch `[::events/navigate :inbox]` happens on init. Inbox should show episodes fetched from `GET /inbox`.

Expected: Episode list renders, filter checkboxes work (client-side filtering, no network request).

- [ ] **Step 4: Commit**

```bash
git add src/cljs/buzz_bot/views/miniplayer.cljs src/cljs/buzz_bot/views/inbox.cljs
git commit -m "feat: implement miniplayer bar and inbox view"
```

---

### Task 12: CLJS — Feeds and Episodes views

**Files:**
- Modify: `src/cljs/buzz_bot/views/feeds.cljs`
- Modify: `src/cljs/buzz_bot/views/episodes.cljs`

- [ ] **Step 1: Implement `views/feeds.cljs`**

```clojure
(ns buzz-bot.views.feeds
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- feed-card [feed]
  [:div.feed-card
   (when (:image_url feed)
     [:div.feed-artwork {:style {:background-image (str "url('" (:image_url feed) "')")}}])
   [:div.feed-info
    [:span.feed-title (:title feed)]
    [:span.feed-url   (:url feed)]]
   [:div.feed-actions
    [:button.btn-episodes
     {:on-click #(rf/dispatch [::events/navigate :episodes {:feed-id (:id feed)}])}
     "Episodes"]
    [:button.btn-unsubscribe
     {:on-click #(rf/dispatch [::events/unsubscribe-feed (:id feed)])}
     "Unsubscribe"]]])

(defn view []
  (let [url-atom  (r/atom "")
        feeds     (rf/subscribe [::subs/feeds-list])
        loading?  (rf/subscribe [::subs/feeds-loading?])]
    (fn []
      [:div.feeds-container
       [:div.section-header [:h2 "Feeds"]]
       [:div.subscribe-form
        [:input.feed-url-input
         {:type        "url"
          :placeholder "Paste RSS feed URL..."
          :value       @url-atom
          :on-change   #(reset! url-atom (-> % .-target .-value))}]
        [:button.btn-subscribe
         {:on-click #(when (seq @url-atom)
                       (rf/dispatch [::events/subscribe-feed @url-atom])
                       (reset! url-atom ""))}
         "Subscribe"]]
       (cond
         @loading?         [:div.loading "Loading..."]
         (empty? @feeds)   [:div.empty-msg "No feeds yet. Subscribe to a podcast!"]
         :else
         [:div.feeds-list
          (for [feed @feeds]
            ^{:key (:id feed)} [feed-card feed])])])))
```

- [ ] **Step 2: Implement `views/episodes.cljs`**

```clojure
(ns buzz-bot.views.episodes
  (:require [re-frame.core :as rf]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- episode-item [ep]
  [:li.episode-item
   {:class           (when (:listened ep) "listened")
    :data-episode-id (str (:id ep))
    :on-click        #(rf/dispatch [::events/navigate :player {:episode-id (:id ep)}])}
   [:div.episode-info
    [:span.episode-title (:title ep)]]
   [:span.episode-play "▶"]])

(defn view []
  (let [episodes  @(rf/subscribe [::subs/episodes-list])
        loading?  @(rf/subscribe [::subs/episodes-loading?])
        has-more? @(rf/subscribe [::subs/episodes-has-more?])
        order     @(rf/subscribe [::subs/episodes-order])
        {:keys [feed-id]} @(rf/subscribe [:buzz-bot.subs/view-params])]
    [:div.episodes-container
     [:div.section-header
      [:button.btn-back
       {:on-click #(rf/dispatch [::events/navigate :feeds])}
       "← Feeds"]
      [:label.filter-label
       [:input.filter-checkbox
        {:type      "checkbox"
         :checked   (= order :asc)
         :on-change #(rf/dispatch [::events/set-order (if (= order :asc) :desc :asc)])}]
       [:span.filter-switch]
       [:span "Oldest first"]]]
     (cond
       (and loading? (empty? episodes)) [:div.loading "Loading..."]
       (empty? episodes) [:div.empty-msg "No episodes in this feed."]
       :else
       [:<>
        [:ul.episode-list#episode-list
         {:data-feed-id (str feed-id)}
         (for [ep episodes]
           ^{:key (:id ep)} [episode-item ep])]
        (when has-more?
          [:button.btn-load-more
           {:on-click #(rf/dispatch [::events/load-more-episodes])
            :disabled loading?}
           (if loading? "Loading..." "Load more")])])]))
```

- [ ] **Step 3: Verify feeds and episode list in browser**

Navigate to Feeds tab. Subscribe form should work. Click "Episodes" on a feed — episode list should render. "Oldest first" toggle should reload with `order=asc`.

- [ ] **Step 4: Commit**

```bash
git add src/cljs/buzz_bot/views/feeds.cljs src/cljs/buzz_bot/views/episodes.cljs
git commit -m "feat: implement feeds list and episode list views"
```

---

### Task 13: CLJS — Player view

**Files:**
- Modify: `src/cljs/buzz_bot/views/player.cljs`

- [ ] **Step 1: Implement `views/player.cljs`**

```clojure
(ns buzz-bot.views.player
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- fmt-time [sec]
  (if (or (js/isNaN sec) (neg? sec) (not (js/isFinite sec)))
    "--:--"
    (let [h (js/Math.floor (/ sec 3600))
          m (js/Math.floor (/ (mod sec 3600) 60))
          s (js/Math.floor (mod sec 60))]
      (if (pos? h)
        (str h ":" (.padStart (str m) 2 "0") ":" (.padStart (str s) 2 "0"))
        (str m ":" (.padStart (str s) 2 "0"))))))

(defn- seek-bar [current duration pending?]
  (let [pct (if (pos? duration) (* 100 (/ current duration)) 0)]
    [:input.player-seek-bar#player-seek
     {:type      "range" :min 0 :max 100 :step 0.1
      :value     pct
      :disabled  pending?
      :style     {"--pct" (str (.toFixed pct 2) "%")}
      :on-change #(when (pos? duration)
                    (rf/dispatch [::events/audio-seek
                                  (* (/ (.. % -target -value) 100) duration)]))}]))

(defn view []
  (let [data      @(rf/subscribe [::subs/player-data])
        loading?  @(rf/subscribe [::subs/player-loading?])
        playing?  @(rf/subscribe [::subs/audio-playing?])
        pending?  @(rf/subscribe [::subs/audio-pending?])
        cur-time  @(rf/subscribe [::subs/audio-current-time])
        duration  @(rf/subscribe [::subs/audio-duration])
        rate      @(rf/subscribe [::subs/audio-rate])
        params    @(rf/subscribe [:buzz-bot.subs/view-params])]
    (cond
      loading?  [:div.loading "Loading episode..."]
      (nil? data) [:div.error-msg "Episode not found."]
      :else
      (let [{:keys [episode feed user_episode next_id recs is_subscribed is_premium]} data
            liked?     (= true (:liked user_episode))
            autoplay?  @(rf/subscribe [:buzz-bot.subs/audio])]
        [:div.player-container#player-root
         [:div.section-header
          [:div.section-header-row
           [:button.btn-back
            {:on-click #(rf/dispatch [::events/navigate
                                      (keyword (get params :from "feeds"))
                                      (when (= "episodes" (get params :from))
                                        {:feed-id (:feed_id episode)})])}
            "← Back"]]]
         [:div.player-card
          [:div.player-title-row
           [:h2.player-title (:title episode)]]

          [:div.player-controls
           [:div.player-progress-row
            [:span.player-time#player-current-time (fmt-time cur-time)]
            [seek-bar cur-time duration pending?]
            [:span.player-time#player-duration (fmt-time duration)]]
           [:div.player-buttons-row
            [:button.btn-seek {:on-click #(rf/dispatch [::events/audio-seek-relative -15])}
             [:span.btn-seek-icon "↺"] [:span.btn-seek-label "15s"]]
            [:button.btn-play-pause-large#player-play-pause
             {:on-click #(rf/dispatch [::events/toggle-play-pause])}
             (cond pending? "▶" playing? "⏸" :else "▶")]
            [:button.btn-seek {:on-click #(rf/dispatch [::events/audio-seek-relative 30])}
             [:span.btn-seek-icon "↻"] [:span.btn-seek-label "30s"]]]
           [:div.player-speed-row
            [:button.btn-speed#player-speed-btn
             {:class    (when (not= rate 1) "btn-speed--active")
              :on-click #(rf/dispatch [::events/cycle-speed])}
             (if (= rate 1) "1×" (str rate "×"))]]]

          [:div.autoplay-row
           [:label.autoplay-label {:class (when-not next_id "autoplay-label--disabled")}
            [:input.autoplay-checkbox#autoplay-checkbox
             {:type      "checkbox"
              :disabled  (not next_id)
              :checked   (:autoplay? @(rf/subscribe [::subs/audio]))
              :on-change #(rf/dispatch [::events/toggle-autoplay])}]
            [:span.autoplay-switch]
            [:span.autoplay-text
             (if next_id "Play next episode after this one" "Last episode in feed")]]]

          [:div.player-actions
           [:div.like-buttons
            [:button.btn-like
             {:class    (when liked? "active")
              :on-click #(rf/dispatch [::events/toggle-bookmark (:id episode)])}
             (if liked? "Bookmarked" "Bookmark")]]]

          (when-not is_subscribed
            [:div.subscribe-row
             [:button.btn-subscribe
              {:on-click #(rf/dispatch [::events/subscribe-from-player (:feed_id episode)])}
              (str "➕ Subscribe to " (or (:title feed) "this podcast"))]])

          (when (seq recs)
            [:div.recs-section
             [:h3.recs-title "Listeners also liked"]
             [:ul.recs-list
              (for [rec recs]
                ^{:key (:id rec)}
                [:li.rec-item
                 {:on-click #(rf/dispatch [::events/navigate :player {:episode-id (:id rec)}])}
                 [:div.rec-info
                  [:span.rec-feed  (:feed_title rec)]
                  [:span.rec-title (:title rec)]]
                 [:span.rec-play "▶"]])]])]]))))
```

- [ ] **Step 2: Verify player in browser**

Click an episode from inbox. Player should render with controls, seek bar, play/pause, speed, bookmark. Try play/pause, seek, speed change. Navigate to another episode while playing — miniplayer should keep playing, player shows ▶.

- [ ] **Step 3: Commit**

```bash
git add src/cljs/buzz_bot/views/player.cljs
git commit -m "feat: implement full player view with pending episode support"
```

---

### Task 14: CLJS — Bookmarks view

**Files:**
- Modify: `src/cljs/buzz_bot/views/bookmarks.cljs`

- [ ] **Step 1: Implement `views/bookmarks.cljs`**

```clojure
(ns buzz-bot.views.bookmarks
  (:require [re-frame.core :as rf]
            [reagent.core :as r]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]))

(defn- episode-item [ep]
  [:li.episode-item
   {:data-episode-id (str (:id ep))
    :on-click        #(rf/dispatch [::events/navigate :player
                                    {:episode-id (:id ep) :from "bookmarks"}])}
   [:div.episode-info
    [:span.episode-feed  (:feed_title ep)]
    [:span.episode-title (:title ep)]]
   [:span.episode-play "▶"]])

(defn view []
  (let [query-atom (r/atom "")
        debounce   (atom nil)]
    (fn []
      (let [episodes @(rf/subscribe [::subs/bookmarks-list])
            loading? @(rf/subscribe [::subs/bookmarks-loading?])]
        [:div.bookmarks-container
         [:div.section-header [:h2 "Bookmarks"]]
         [:div.search-row
          [:input.search-input
           {:type        "search"
            :placeholder "Search bookmarks..."
            :on-change   (fn [e]
                           (let [v (.. e -target -value)]
                             (reset! query-atom v)
                             (when @debounce (js/clearTimeout @debounce))
                             (reset! debounce
                               (js/setTimeout
                                 #(rf/dispatch [::events/search-bookmarks v])
                                 300))))}]]
         (cond
           loading?         [:div.loading "Loading..."]
           (empty? episodes) [:div.empty-msg "No bookmarks yet. Like an episode to save it."]
           :else
           [:ul.episode-list
            (for [ep episodes]
              ^{:key (:id ep)} [episode-item ep])])]))))
```

- [ ] **Step 2: Verify in browser**

Switch to Bookmarks tab. Liked episodes should appear. Search should filter in real time (debounced 300ms).

- [ ] **Step 3: Commit**

```bash
git add src/cljs/buzz_bot/views/bookmarks.cljs
git commit -m "feat: implement bookmarks view with debounced search"
```

---

### Task 15: Cutover — replace layout.ecr and delete dead files

**Files:**
- Modify: `src/views/layout.ecr` (replace with SPA shell)
- Modify: `src/web/routes/app.cr` (remove /app-spa test route)
- Delete: All old ECR templates, JS files, SW

**Prerequisites:** All views work correctly in browser at `/app-spa`.

- [ ] **Step 1: Replace `src/views/layout.ecr` with the SPA shell**

Replace the entire file contents:
```ecr
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Buzz-Bot</title>
  <script src="/js/telegram-web-app.js"></script>
  <link rel="stylesheet" href="/css/app.css?v=<%= Assets::VERSION %>">
</head>
<body>
  <div id="app"></div>
  <script>window.BOT_USERNAME = '<%= BotClient.username %>';</script>
  <script src="/js/main.js?v=<%= Assets::VERSION %>"></script>
</body>
</html>
```

- [ ] **Step 2: Remove the `/app-spa` test route from `src/web/routes/app.cr`**

Delete the entire `get "/app-spa"` block.

- [ ] **Step 3: Delete dead ECR templates**

```bash
cd /home/watchcat/work/crystal/buzz-bot
rm src/views/inbox.ecr src/views/inbox_items.ecr \
   src/views/episode_list.ecr src/views/episode_items.ecr \
   src/views/player.ecr src/views/like_buttons.ecr \
   src/views/feeds_list.ecr \
   src/views/discover.ecr src/views/discover_results.ecr \
   src/views/search_results.ecr src/views/subscribe_success.ecr \
   src/views/recommendations.ecr 2>/dev/null || true
```

- [ ] **Step 4: Delete dead JS files**

```bash
rm public/js/app.js \
   public/js/miniplayer.js \
   public/js/cache.js \
   public/js/write-queue.js \
   public/js/htmx.min.js \
   public/sw.js
```

- [ ] **Step 5: Delete old Preact source**

```bash
rm -rf src/js/
```

- [ ] **Step 6: Verify Crystal compiles and `GET /app` returns SPA shell**

```bash
crystal build src/buzz_bot.cr --no-codegen 2>&1 | head -20
```

Start server and open `http://localhost:3000/app`. Expected: SPA loads, inbox appears, full app works.

- [ ] **Step 7: Final commit**

```bash
git add -A
git commit -m "feat: cutover to ClojureScript SPA — remove HTMX/ECR/old JS"
```

---

## Build Commands Reference

| Command | Purpose |
|---|---|
| `npx shadow-cljs watch app` | Dev build with hot reload |
| `npx shadow-cljs compile app` | One-off dev build |
| `npx shadow-cljs release app` | Production minified build |
| `crystal build src/buzz_bot.cr --no-codegen` | Check Crystal compiles |
| `./devrun.sh` | Start dev server (Crystal) |

## Key Files Reference

| File | Purpose |
|---|---|
| `shadow-cljs.edn` | Build config, dependencies |
| `src/cljs/buzz_bot/db.cljs` | App-db initial state |
| `src/cljs/buzz_bot/events.cljs` | All state transitions |
| `src/cljs/buzz_bot/subs.cljs` | All derived state |
| `src/cljs/buzz_bot/fx.cljs` | Side effects (fetch, audio) |
| `src/cljs/buzz_bot/audio.cljs` | Audio element interop |
| `src/web/json_helpers.cr` | EpisodeJson + build_episode_list |
