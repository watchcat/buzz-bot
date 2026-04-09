# Dubbing Pipeline v2 — Crystal Side Migration Plan

**Goal:** Replace the three-Crystal-service choreography (dub-transcriber → dub-translator → dub-synthesizer via PostgreSQL NOTIFY channels) with a single Python pipeline service that receives one Redis job from buzz-bot and posts HTTP callbacks when each step progresses or when the job completes.

**Architecture:** buzz-bot's `POST /episodes/:id/dub` route writes the DB row and pushes one JSON job onto a Redis list (`dub:jobs`). The Python pipeline service pops it, runs all steps, and posts HTTP callbacks to two internal endpoints on buzz-bot:
- `POST /internal/dub_progress` — intermediate step updates (fires PG trigger → SSE fan-out to browser)
- `POST /internal/dub_result` — terminal result (success or failure) + Telegram notification to requester

The existing `DubHub` SSE machinery and `dub_status` PG trigger are completely unchanged.

---

## Dependency & Ordering Notes

- Task 2 (model changes) must be done before Tasks 3, 5, 6 (all call model methods)
- Tasks 3, 4, 5, 6 are independent of each other and can be done in parallel after Task 2
- Task 7 (server.cr) must come after Tasks 5 and 6 (the new route files must exist)
- Task 8 (buzz_bot.cr) is independent and can be done at any time
- Task 9 (ClojureScript) is fully independent from all Crystal tasks
- Task 10 (delete retired files) must come last — after Task 8 has removed all `require` statements

---

## File Map

### Modified Crystal files
| File | Change |
|---|---|
| `src/config.cr` | Add `dub_redis_url`, `dub_queue_key`, `dub_callback_base`; remove `deepl_api_key`, `replicate_api_token` |
| `src/models/dubbed_episode.cr` | Rewrite step machine; add `find_by_id`, `set_step`; update `upsert_pending`, `set_complete`; remove 7 v1-only methods |
| `src/web/routes/dub.cr` | After `upsert_pending`, enqueue Redis job directly |
| `src/web/server.cr` | Swap `TranscriptionCallback` require/register for `DubResult` + `DubProgress` |
| `src/buzz_bot.cr` | Remove two `require` lines and the `reset_stale_jobs` call |

### New Crystal files
| File | Responsibility |
|---|---|
| `src/web/routes/dub_result.cr` | `POST /internal/dub_result` — terminal callback + Telegram notify |
| `src/web/routes/dub_progress.cr` | `POST /internal/dub_progress` — intermediate step updates |

### Modified ClojureScript files
| File | Change |
|---|---|
| `src/cljs/buzz_bot/views/dub.cljs` | Update `step->pct` and `step->label` to v2 step names |

### Files to delete
| File | Reason |
|---|---|
| `src/services/dub_transcriber.cr` | Replaced by Python pipeline |
| `src/services/dub_translator.cr` | Replaced by Python pipeline |
| `src/services/dub_synthesizer.cr` | Replaced by Python pipeline |
| `src/dub/deepl_client.cr` | No longer used in buzz-bot |
| `src/dub/replicate_client.cr` | No longer used in buzz-bot |

---

## Task 1: Apply DB Migration

- [ ] Run `migrations/012_dubbing_v2.sql` against production DB (adds `speaker_samples JSONB`, `bg_volume FLOAT`, new `dub_stems`/`dub_segments`/`dub_segment_translations` tables; resets in-flight rows to `failed`)
- [ ] Verify `\d dubbed_episodes` shows `speaker_samples` and `bg_volume` columns
- [ ] Confirm no CHECK constraint on `step` column blocks new step names (`queued`, `separating`, `transcribing`, `translating`, `synthesizing`, `assembling`, `mixing`, `uploading`)

---

## Task 2: `src/config.cr` — Add v2 ENV accessors

- [ ] Add after `whisper_callback_base`:
  ```crystal
  def self.dub_redis_url : String
    ENV["DUB_REDIS_URL"]? || raise "DUB_REDIS_URL not set"
  end

  def self.dub_queue_key : String
    ENV.fetch("DUB_QUEUE_KEY", "dub:jobs")
  end

  def self.dub_callback_base : String
    ENV["DUB_CALLBACK_BASE"]? || raise "DUB_CALLBACK_BASE not set"
  end
  ```
- [ ] Remove `deepl_api_key` accessor (only callers: `src/dub/deepl_client.cr` and `src/services/dub_translator.cr` — both being deleted)
- [ ] Remove `replicate_api_token` accessor (only callers: `src/dub/replicate_client.cr` and `src/services/dub_synthesizer.cr` — both being deleted)

---

## Task 3: `src/models/dubbed_episode.cr` — Rewrite step machine

### 3a. Add `find_by_id`
After the existing `find(episode_id, language)` method:
```crystal
def self.find_by_id(id : Int64) : DubbedEpisode?
  AppDB.pool.query_one?(
    <<-SQL,
      SELECT id, episode_id, language, status, step, r2_url, translation,
             error, expires_at, created_at, requester_telegram_id
      FROM dubbed_episodes WHERE id = $1
    SQL
    id
  ) { |rs| from_rs(rs) }
end
```

### 3b. Update `upsert_pending`
- Change initial step `'transcription'` → `'queued'`
- Change ON CONFLICT step reset `'transcription'` → `'queued'`
- Remove the `_notify` CTE calling `pg_notify('dub_transcription', ...)` — enqueue now happens in the route

```crystal
def self.upsert_pending(episode_id : Int64, language : String, requester_telegram_id : Int64) : Int64
  AppDB.pool.query_one(
    <<-SQL,
      INSERT INTO dubbed_episodes (episode_id, language, status, step, requester_telegram_id)
      VALUES ($1, $2, 'pending', 'queued', $3)
      ON CONFLICT (episode_id, language) DO UPDATE
        SET status                = 'pending',
            step                  = 'queued',
            r2_url                = NULL,
            translation           = NULL,
            error                 = NULL,
            expires_at            = NULL,
            requester_telegram_id = $3,
            created_at            = NOW()
      RETURNING id
    SQL
    episode_id, language, requester_telegram_id, as: Int64
  )
end
```

### 3c. Add `set_step`
After `set_processing`:
```crystal
def self.set_step(id : Int64, step : String)
  AppDB.pool.exec(
    "UPDATE dubbed_episodes SET step = $2 WHERE id = $1",
    id, step
  )
  # The dub_update_notify PG trigger fires automatically on every UPDATE,
  # fanning out a 'dub_status' NOTIFY to DubHub → SSE clients.
end
```

### 3d. Update `set_complete`
Add `speaker_samples` parameter:
```crystal
def self.set_complete(id : Int64, r2_url : String?, speaker_samples : String? = nil)
  AppDB.pool.exec(
    <<-SQL,
      UPDATE dubbed_episodes
      SET step = 'complete', status = 'done', r2_url = $2,
          speaker_samples = $3::jsonb,
          expires_at = NOW() + INTERVAL '29 days'
      WHERE id = $1
    SQL
    id, r2_url, speaker_samples
  )
end
```

### 3e. Remove v1-only methods
Delete entirely:
- `reset_stale_jobs`
- `claim_for_transcription`
- `claim_for_translation`
- `claim_for_synthesis`
- `advance_to_translation`
- `advance_to_synthesis`
- `reset_in_flight`

---

## Task 4: `src/web/routes/dub.cr` — Enqueue to Redis

Add `require "redis"` at the top.

In `POST /episodes/:id/dub`, replace the final response block (after `upsert_pending`) with:

```crystal
dub_id = DubbedEpisode.upsert_pending(episode_id, language, user.telegram_id)

begin
  bg_volume    = data["bg_volume"]?.try(&.as_f?) || 0.15
  job_id       = Random::Secure.hex(16)
  callback_base = Config.dub_callback_base
  payload = {
    job_id:        job_id,
    dub_id:        dub_id,
    episode_id:    episode_id,
    audio_url:     episode.audio_url,
    language:      language,
    bg_volume:     bg_volume,
    callback_url:  "#{callback_base}/internal/dub_result",
  }.to_json
  r = Redis::Client.new(URI.parse(Config.dub_redis_url))
  r.run({"RPUSH", Config.dub_queue_key, payload})
  Log.info { "Dub[#{dub_id}]: job #{job_id} enqueued → dub pipeline (episode #{episode_id} → #{language})" }
rescue ex
  Log.error { "Dub[#{dub_id}]: failed to enqueue — #{ex.message}" }
  DubbedEpisode.set_failed(dub_id, "Failed to enqueue job: #{ex.message}")
  env.response.content_type = "application/json"
  env.response.status_code = 500
  next %({"error":"enqueue_failed"})
end

env.response.content_type = "application/json"
env.response.status_code = 202
%({"id":#{dub_id},"status":"pending"})
```

---

## Task 5: New `src/web/routes/dub_result.cr`

```crystal
require "json"
require "../../models/dubbed_episode"

module Web::Routes::DubResult
  private struct Result
    include JSON::Serializable
    getter job_id          : String
    getter dub_id          : Int64
    getter episode_id      : Int64?
    getter language        : String?
    getter success         : Bool
    getter r2_url          : String?
    getter duration_sec    : Float64?
    getter segment_count   : Int32?
    getter speaker_count   : Int32?
    getter speaker_samples : String?
    getter step            : String?
    getter error           : String?
  end

  def self.register
    post "/internal/dub_result" do |env|
      body   = env.request.body.try(&.gets_to_end) || ""
      result = Result.from_json(body)

      unless result.success
        Log.error { "DubResult[#{result.dub_id}]: job #{result.job_id} failed at step=#{result.step} — #{result.error}" }
        DubbedEpisode.set_failed(result.dub_id, result.error || "Pipeline failed")
        env.response.content_type = "application/json"
        next {ok: true}.to_json
      end

      Log.info { "DubResult[#{result.dub_id}]: job #{result.job_id} done — #{result.r2_url}" }
      DubbedEpisode.set_complete(result.dub_id, result.r2_url, result.speaker_samples)

      if (dub = DubbedEpisode.find_by_id(result.dub_id))
        notify_user(
          dub_id:          result.dub_id,
          episode_id:      result.episode_id || dub.episode_id,
          language:        result.language   || dub.language,
          requester_tg_id: dub.requester_telegram_id
        )
      end

      env.response.content_type = "application/json"
      {ok: true}.to_json
    rescue ex : JSON::ParseException
      Log.error { "DubResult: malformed payload — #{ex.message}" }
      env.response.status_code = 400
      {error: "Invalid JSON"}.to_json
    rescue ex
      Log.error { "DubResult: #{ex.message}" }
      env.response.status_code = 500
      {error: "Internal error"}.to_json
    end
  end

  private def self.notify_user(dub_id : Int64, episode_id : Int64,
                                language : String, requester_tg_id : Int64?)
    return unless requester_tg_id
    app_url = "#{Config.base_url}/app?episode=#{episode_id}"
    BotClient.client.send_message(
      requester_tg_id,
      "🎙 Your dubbed episode is ready in #{language.upcase}.",
      reply_markup: Tourmaline::InlineKeyboardMarkup.new([[
        Tourmaline::InlineKeyboardButton.new(
          text: "▶️ Open Episode",
          web_app: Tourmaline::WebAppInfo.new(url: app_url)
        )
      ]])
    )
  rescue ex
    Log.warn { "DubResult[#{dub_id}]: Telegram notification failed — #{ex.message}" }
  end
end
```

---

## Task 6: New `src/web/routes/dub_progress.cr`

```crystal
require "json"
require "../../models/dubbed_episode"

module Web::Routes::DubProgress
  private struct Payload
    include JSON::Serializable
    getter dub_id : Int64
    getter step   : String
    getter pct    : Float64?
  end

  def self.register
    post "/internal/dub_progress" do |env|
      body    = env.request.body.try(&.gets_to_end) || ""
      payload = Payload.from_json(body)

      DubbedEpisode.set_step(payload.dub_id, payload.step)
      Log.info { "DubProgress[#{payload.dub_id}]: step=#{payload.step}#{payload.pct ? " (#{payload.pct}%)" : ""}" }

      env.response.content_type = "application/json"
      {ok: true}.to_json
    rescue ex : JSON::ParseException
      Log.error { "DubProgress: malformed payload — #{ex.message}" }
      env.response.status_code = 400
      {error: "Invalid JSON"}.to_json
    rescue ex
      Log.error { "DubProgress: #{ex.message}" }
      env.response.status_code = 500
      {error: "Internal error"}.to_json
    end
  end
end
```

---

## Task 7: `src/web/server.cr` — Swap route registrations

- [ ] Replace `require "./routes/transcription_callback"` with:
  ```crystal
  require "./routes/dub_result"
  require "./routes/dub_progress"
  ```
- [ ] Replace `Web::Routes::TranscriptionCallback.register` with:
  ```crystal
  Web::Routes::DubResult.register
  Web::Routes::DubProgress.register
  ```

---

## Task 8: `src/buzz_bot.cr` — Remove v1 artifacts

- [ ] Remove `require "./dub/replicate_client"`
- [ ] Remove `require "./dub/deepl_client"`
- [ ] Remove `DubbedEpisode.reset_stale_jobs` call

---

## Task 9: `src/cljs/buzz_bot/views/dub.cljs` — Update step labels

Replace `step->pct` and `step->label` with v2 step names:

```clojure
(defn- step->pct [step]
  (case step
    "queued"                  "5%"
    "separating"              "15%"
    "transcribing"            "30%"
    "translating"             "50%"
    "synthesizing"            "70%"
    "assembling"              "90%"
    ("mixing" "uploading")    "95%"
    "5%"))

(defn- step->label [step]
  (case step
    "queued"                  "Starting…"
    "separating"              "Separating audio stems…"
    "transcribing"            "Transcribing audio…"
    "translating"             "Translating…"
    "synthesizing"            "Synthesizing dubbed voice…"
    "assembling"              "Assembling timeline…"
    ("mixing" "uploading")    "Finishing up…"
    "Starting…"))
```

---

## Task 10: Delete retired files

Only after Task 8 has removed all `require` references:

- [ ] Delete `src/services/dub_transcriber.cr`
- [ ] Delete `src/services/dub_translator.cr`
- [ ] Delete `src/services/dub_synthesizer.cr`
- [ ] Delete `src/dub/deepl_client.cr`
- [ ] Delete `src/dub/replicate_client.cr`

---

## Rollout Sequence

1. Apply migration `012_dubbing_v2.sql` to production DB
2. Deploy Python dub-pipeline service, confirm it listens on `dub:jobs`
3. Set `DUB_REDIS_URL`, `DUB_QUEUE_KEY`, `DUB_CALLBACK_BASE` in k8s secret
4. Build and deploy buzz-bot with all Crystal changes
5. Verify end-to-end with a test dub request
6. Delete old dub-transcriber/translator/synthesizer k8s Deployments from cluster

---

## Potential Pitfalls

- **`speaker_samples` cast:** `set_complete` casts to `::jsonb` in SQL. If Python sends `null`, Crystal passes `nil` as SQL NULL — fine, column is nullable.
- **Redis connection per request:** Creating `Redis::Client` on every dub request is safe. Per-request is simplest correct approach.
- **`transcription_callback.cr` still serves whisper-worker:** The whisper-worker is still used for standalone episode transcription (not dubs). The `dub_id` branch (`advance_to_translation`) in that file becomes dead code — clean it up but don't delete the file or the endpoint.
- **`episode.audio_url` type:** `String` (not nullable) — no nil-check needed in the enqueue block.
