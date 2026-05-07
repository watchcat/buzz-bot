# Tag Cloud Tab

A new "Topics" tab that shows a tag cloud of the 100 most frequent KeyBERT topics from the user's subscribed episodes. Clicking a tag filters the episode list to only episodes with that tag.

## Problem

Users have no way to browse their subscriptions by topic. The inbox is chronological, search requires knowing what to type. A tag cloud gives a visual overview of what topics the user's feeds cover and lets them drill into any topic with one tap.

## Data Source

Topics come from `episode_embeddings.topics`, a `TEXT[]` column populated by KeyBERT during the embedding pipeline. Each episode has up to 10 keyphrases. Only episodes from the user's subscribed feeds are included.

## Backend

### Endpoint

```
GET /topics
GET /topics?tag=economics
```

Single endpoint, two modes:

- **No `tag` param:** Returns top 100 tags with episode counts + all user episodes in chronological order (same as inbox)
- **With `tag` param:** Returns the same tag cloud + episodes filtered to those containing the given tag

Both modes support `limit` and `offset` for episode pagination.

### Tag Cloud Query

```sql
SELECT t AS tag, COUNT(*) AS count
FROM episodes e
JOIN user_feeds uf ON uf.feed_id = e.feed_id
JOIN episode_embeddings ee ON ee.episode_id = e.id,
     unnest(ee.topics) AS t
WHERE uf.user_id = $1
GROUP BY t
ORDER BY count DESC
LIMIT $2
```

### Filtered Episodes Query

Same structure as `Episode.for_inbox` but with an additional join to `episode_embeddings` and a filter:

```sql
SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url,
       e.duration_sec, e.published_at, e.image_url
FROM episodes e
JOIN user_feeds uf ON uf.feed_id = e.feed_id
JOIN episode_embeddings ee ON ee.episode_id = e.id
WHERE uf.user_id = $1
  AND $2 = ANY(ee.topics)
ORDER BY COALESCE(e.published_at, e.created_at) DESC
LIMIT $3 OFFSET $4
```

When no tag is selected, the query omits the `JOIN episode_embeddings` and the `ANY` filter — identical to the existing inbox query.

### New Model Method

`EpisodeEmbedding.top_tags_for_user(user_id : Int64, limit : Int32 = 100) : Array(TagCount)` where `TagCount` is a `record` with `tag : String, count : Int32`.

`Episode.for_topic(user_id : Int64, tag : String, limit : Int32 = 100, offset : Int32 = 0) : Array(Episode)` for filtered episode list.

### Response Shape

```json
{
  "tags": [
    {"tag": "technology", "count": 42},
    {"tag": "AI", "count": 38},
    ...
  ],
  "episodes": [
    {
      "id": 123,
      "title": "...",
      "feed_title": "...",
      ...
    }
  ],
  "has_more": false
}
```

Episodes use the same `EpisodeJson` shape as inbox — enriched with feed info, user progress, liked status via `Web.build_episode_list`.

### New Route File

`src/web/routes/topics.cr` — registered in the server setup alongside other route modules.

## Frontend

### New Tab

"Topics" added as 4th tab in the tab bar (after Bookmarks). Icon: `🏷`. Navigation: `(rf/dispatch [::events/navigate :topics])`.

### State

```clojure
:topics {:tags [] :episodes [] :loading? false :selected-tag nil}
```

Added to `default-db` in `src/cljs/buzz_bot/db.cljs`.

### Events

- `::fetch-topics` — calls `GET /topics`, stores tags and episodes
- `::select-tag` — sets `:selected-tag`, calls `GET /topics?tag=X`
- `::clear-tag` — clears `:selected-tag`, calls `GET /topics`
- `::topics-loaded` — writes response into `[:topics]` state

### Subscriptions

- `::topics-tags` — `(get-in db [:topics :tags])`
- `::topics-episodes` — `(get-in db [:topics :episodes])`
- `::topics-loading?` — `(get-in db [:topics :loading?])`
- `::topics-selected-tag` — `(get-in db [:topics :selected-tag])`

### Tag Cloud Component

Collapsible tag cloud, shows top ~20 tags by default with a "Show all" toggle to expand to 100.

- Tag font size scaled linearly by count: min 11px, max 22px, interpolated between the lowest and highest counts in the response
- Tags displayed as inline `span` elements with `flex-wrap` layout
- Selected tag: accent color + bold
- Clicking a tag dispatches `::select-tag`
- Clicking the already-selected tag dispatches `::clear-tag`
- Local `r/atom` for expanded/collapsed state
- "Show all N tags" / "Show less" toggle text

### Episode List

Same `episode-item` rendering as inbox — reuse the existing component. Episodes are clickable, navigate to player. No additional filters (no hide-listened, no compact mode) — keep it simple.

When a tag is selected, show a label above the list: `"economics" · 24 episodes`. When no tag is selected: `All episodes`.

### View File

`src/cljs/buzz_bot/views/topics.cljs` — new file, required in `core.cljs`.

### Navigation Integration

- Add `:topics` case to `core.cljs` view dispatch
- Add tab button to `layout.cljs` tab bar
- `::navigate` event triggers `::fetch-topics` when entering the topics view

## What Doesn't Change

- Inbox, Feeds, Bookmarks tabs — unchanged
- Episode item rendering — reused as-is
- Embedding pipeline — no changes, topics already populated
- Database schema — no migrations, read-only access to existing `episode_embeddings.topics`
- Recommendation system — unaffected
