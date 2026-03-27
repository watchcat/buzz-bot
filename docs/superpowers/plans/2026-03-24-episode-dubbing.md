# Episode Dubbing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add on-demand episode dubbing for premium users — user picks a language, backend runs Whisper → DeepL → XTTS-v2 async, result stored on R2 and delivered via Telegram + in-app player.

**Architecture:** Crystal fiber (fire-and-forget, same pattern as `AudioSender`) chains three external API calls: Replicate Whisper for transcription, DeepL for translation, Replicate XTTS-v2 for TTS synthesis. Output is stored on Cloudflare R2 for 29 days (DB) / 31 days (R2 lifecycle). Frontend polls `GET /episodes/:id/dub/:language` every 5s and swaps the audio source when ready.

**Tech Stack:** Crystal/Kemal (backend), PostgreSQL (Neon), Cloudflare R2 (S3-compatible storage), Replicate API, DeepL API, ClojureScript/Re-frame (frontend).

**Spec:** `docs/superpowers/specs/2026-03-24-episode-dubbing-design.md`

---

## File Map

### New Crystal files
| File | Responsibility |
|---|---|
| `migrations/007_dubbed_episodes.sql` | `dubbed_episodes` table + `users.preferred_dub_language` column |
| `src/models/dubbed_episode.cr` | DB model: upsert, find, status helpers |
| `src/dub/replicate_client.cr` | Submit Replicate prediction + poll until done (20-min timeout) |
| `src/dub/deepl_client.cr` | DeepL `/v2/translate` call |
| `src/dub/r2_storage.cr` | Upload bytes to Cloudflare R2 via S3-compatible API (SigV4) |
| `src/dub/dub_job.cr` | Pipeline fiber: transcribe → translate → synthesize → upload → notify |
| `src/web/routes/dub.cr` | POST /episodes/:id/dub, GET /episodes/:id/dub/:language, PUT /user/dub_language |

### Modified Crystal files
| File | Change |
|---|---|
| `src/config.cr` | Add R2, Replicate, DeepL ENV accessors |
| `src/models/user.cr` | Add `preferred_dub_language : String?` field |
| `src/web/routes/episodes.cr` | Extend POST /episodes/:id/send to accept `dubbed: true` |
| `src/web/server.cr` | Register `Web::Routes::Dub` |
| `src/buzz_bot.cr` | Require new files; reset pending/processing dub rows on startup |

### New CLJS files
| File | Responsibility |
|---|---|
| `src/cljs/buzz_bot/events/dub.cljs` | Re-frame events for dub lifecycle |
| `src/cljs/buzz_bot/subs/dub.cljs` | Re-frame subscriptions for dub state |
| `src/cljs/buzz_bot/views/dub.cljs` | Language picker modal + dub state display |

### Modified CLJS files
| File | Change |
|---|---|
| `src/cljs/buzz_bot/db.cljs` | Add `:dub` key to `default-db` |
| `src/cljs/buzz_bot/fx.cljs` | Add `::poll-after` effect for deferred dispatch |
| `src/cljs/buzz_bot/core.cljs` | Require new dub event/sub namespaces |
| `src/cljs/buzz_bot/views/player.cljs` | Add dub button and state display |

---

## Task 1: DB Migration

**Files:**
- Create: `migrations/007_dubbed_episodes.sql`

- [ ] **Step 1: Create migration file**

```sql
-- migrations/007_dubbed_episodes.sql
ALTER TABLE users ADD COLUMN preferred_dub_language VARCHAR(10);

CREATE TABLE dubbed_episodes (
  id           BIGSERIAL PRIMARY KEY,
  episode_id   BIGINT NOT NULL REFERENCES episodes(id),
  language     VARCHAR(10) NOT NULL,
  status       VARCHAR(20) NOT NULL DEFAULT 'pending',
  r2_url       TEXT,
  error        TEXT,
  expires_at   TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (episode_id, language)
);

CREATE INDEX dubbed_episodes_episode_id_idx ON dubbed_episodes(episode_id);
```

- [ ] **Step 2: Run migration against Neon DB**

Get the `DATABASE_URL` from k8s secret or `.env`, then:

```bash
psql "$DATABASE_URL" -f migrations/007_dubbed_episodes.sql
```

Expected output:
```
ALTER TABLE
CREATE TABLE
CREATE INDEX
```

- [ ] **Step 3: Verify schema**

```bash
psql "$DATABASE_URL" -c "\d dubbed_episodes"
psql "$DATABASE_URL" -c "\d users" | grep preferred_dub
```

- [ ] **Step 4: Commit**

```bash
git add migrations/007_dubbed_episodes.sql
git commit -m "feat(dub): add dubbed_episodes table and users.preferred_dub_language"
```

---

## Task 2: Config — ENV Var Accessors

**Files:**
- Modify: `src/config.cr`

The project reads ENV via `Config.method_name`. Add accessors for all new services.

- [ ] **Step 1: Append to `src/config.cr`**

Add inside the `module Config` block at the end of `src/config.cr`:

```crystal
  def self.replicate_api_token : String
    ENV["REPLICATE_API_TOKEN"]? || raise "REPLICATE_API_TOKEN not set"
  end

  def self.deepl_api_key : String
    ENV["DEEPL_API_KEY"]? || raise "DEEPL_API_KEY not set"
  end

  def self.r2_account_id : String
    ENV["R2_ACCOUNT_ID"]? || raise "R2_ACCOUNT_ID not set"
  end

  def self.r2_access_key_id : String
    ENV["R2_ACCESS_KEY_ID"]? || raise "R2_ACCESS_KEY_ID not set"
  end

  def self.r2_secret_access_key : String
    ENV["R2_SECRET_ACCESS_KEY"]? || raise "R2_SECRET_ACCESS_KEY not set"
  end

  def self.r2_bucket : String
    ENV["R2_BUCKET"]? || raise "R2_BUCKET not set"
  end

  def self.r2_public_url : String
    ENV["R2_PUBLIC_URL"]? || raise "R2_PUBLIC_URL not set"
  end
```

- [ ] **Step 2: Verify it compiles**

```bash
crystal build src/buzz_bot.cr --no-codegen 2>&1 | head -20
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/config.cr
git commit -m "feat(dub): add Config accessors for Replicate, DeepL, R2"
```

---

## Task 3: DubbedEpisode Model

**Files:**
- Create: `src/models/dubbed_episode.cr`

This model wraps the `dubbed_episodes` table. Note: `expired` is not a stored status — it's derived at query time from `expires_at < NOW()`. The model returns the stored status plus an `expired?` check.

- [ ] **Step 1: Create the model file**

```crystal
# src/models/dubbed_episode.cr
require "json"

# Language allowlist — intersection of XTTS-v2 and DeepL supported languages.
DUB_LANGUAGES = %w[en es fr de it pt pl tr ru nl cs zh ja hu ko]

struct DubbedEpisode
  include JSON::Serializable

  property id         : Int64
  property episode_id : Int64
  property language   : String
  property status     : String   # "pending" | "processing" | "done" | "failed"
  property r2_url     : String?
  property error      : String?
  property expires_at : Time?
  property created_at : Time

  def initialize(@id, @episode_id, @language, @status, @r2_url, @error, @expires_at, @created_at)
  end

  # Derived: a "done" row whose 29-day window has passed is logically expired.
  def expired? : Bool
    status == "done" && (expires_at.try { |t| t < Time.utc } || false)
  end

  # effective_status returns the status the API should surface to the client.
  def effective_status : String
    expired? ? "expired" : status
  end

  private def self.from_rs(rs) : DubbedEpisode
    new(
      rs.read(Int64),   # id
      rs.read(Int64),   # episode_id
      rs.read(String),  # language
      rs.read(String),  # status
      rs.read(String?), # r2_url
      rs.read(String?), # error
      rs.read(Time?),   # expires_at
      rs.read(Time)     # created_at
    )
  end

  # Find the current dub row for an (episode, language) pair.
  def self.find(episode_id : Int64, language : String) : DubbedEpisode?
    AppDB.pool.query_one?(
      <<-SQL,
        SELECT id, episode_id, language, status, r2_url, error, expires_at, created_at
        FROM dubbed_episodes
        WHERE episode_id = $1 AND language = $2
      SQL
      episode_id, language
    ) { |rs| from_rs(rs) }
  end

  # Upsert: create a new pending row, or reset a failed/expired row back to pending.
  # Returns the row's id.
  def self.upsert_pending(episode_id : Int64, language : String) : Int64
    AppDB.pool.query_one(
      <<-SQL,
        INSERT INTO dubbed_episodes (episode_id, language, status)
        VALUES ($1, $2, 'pending')
        ON CONFLICT (episode_id, language) DO UPDATE
          SET status     = 'pending',
              r2_url     = NULL,
              error      = NULL,
              expires_at = NULL,
              created_at = NOW()
        RETURNING id
      SQL
      episode_id, language, as: Int64
    )
  end

  # Transition pending → processing when the fiber starts.
  def self.set_processing(id : Int64)
    AppDB.pool.exec(
      "UPDATE dubbed_episodes SET status = 'processing' WHERE id = $1",
      id
    )
  end

  # Mark a job as done and store the R2 URL.
  def self.set_done(id : Int64, r2_url : String)
    AppDB.pool.exec(
      <<-SQL,
        UPDATE dubbed_episodes
        SET status = 'done', r2_url = $2, expires_at = NOW() + INTERVAL '29 days'
        WHERE id = $1
      SQL
      id, r2_url
    )
  end

  # Mark a job as failed with an error message.
  def self.set_failed(id : Int64, error : String)
    AppDB.pool.exec(
      "UPDATE dubbed_episodes SET status = 'failed', error = $2 WHERE id = $1",
      id, error
    )
  end

  # On startup: reset any pending or processing rows to failed (process restart
  # kills all fibers — no job can survive a restart).
  def self.reset_stale_jobs
    count = AppDB.pool.exec(
      "UPDATE dubbed_episodes SET status = 'failed', error = 'Server restarted'
       WHERE status IN ('pending', 'processing')"
    ).rows_affected
    Log.info { "DubbedEpisode: reset #{count} stale jobs to failed" } if count > 0
  end
end
```

- [ ] **Step 2: Verify compilation**

```bash
crystal build src/buzz_bot.cr --no-codegen 2>&1 | head -20
```

(You'll need to add the require in buzz_bot.cr first — see Task 8. For now, add a temporary require at the top of any existing model file to spot-check: `require "./dubbed_episode"` then remove it.)

- [ ] **Step 3: Commit**

```bash
git add src/models/dubbed_episode.cr
git commit -m "feat(dub): add DubbedEpisode model with upsert and status helpers"
```

---

## Task 4: Replicate API Client

**Files:**
- Create: `src/dub/replicate_client.cr`

Replicate is async: `POST /v1/models/{owner}/{name}/predictions` submits the job, then you poll `GET /v1/predictions/{id}` until `status` is `"succeeded"` or `"failed"`. We use the model-owner endpoint so no version hash needs to be hardcoded.

- [ ] **Step 1: Create the directory and file**

```bash
mkdir -p src/dub
```

```crystal
# src/dub/replicate_client.cr
require "http/client"
require "json"

module ReplicateClient
  BASE_URL      = "https://api.replicate.com/v1"
  POLL_INTERVAL = 5.seconds
  MAX_POLLS     = 240  # 20 minutes at 5s intervals

  # Run the openai/whisper-large-v3 model and return the transcript text.
  def self.transcribe(audio_url : String) : String
    output = run_model("openai", "whisper-large-v3", {
      "audio"  => audio_url,
      "task"   => "transcribe",
    })
    # Output is a hash: {"text": "...", "segments": [...]}
    output["text"]?.try(&.as_s?) || raise "Whisper returned no text in output"
  end

  # Run lucataco/xtts-v2 and return the URL of the generated MP3.
  def self.synthesize(text : String, speaker_wav : String, language : String) : String
    output = run_model("lucataco", "xtts-v2", {
      "text"        => text,
      "speaker_wav" => speaker_wav,
      "language"    => language,
    })
    # Output is a string URL
    output.as_s? || raise "XTTS-v2 returned unexpected output format: #{output}"
  end

  # Submit a prediction for the given model and poll until succeeded or failed.
  # Returns the raw JSON output value.
  private def self.run_model(owner : String, name : String, input : Hash(String, String)) : JSON::Any
    body = {"input" => input}.to_json

    resp = HTTP::Client.post(
      "#{BASE_URL}/models/#{owner}/#{name}/predictions",
      headers: auth_headers,
      body: body
    )
    raise "Replicate submit failed (#{resp.status_code}): #{resp.body}" unless resp.success?

    pred = JSON.parse(resp.body)
    id   = pred["id"].as_s

    MAX_POLLS.times do
      sleep POLL_INTERVAL
      poll_resp = HTTP::Client.get("#{BASE_URL}/predictions/#{id}", headers: auth_headers)
      pred   = JSON.parse(poll_resp.body)
      status = pred["status"].as_s

      case status
      when "succeeded"
        return pred["output"]
      when "failed", "canceled"
        err = pred["error"]?.try(&.as_s?) || "unknown"
        raise "Replicate prediction #{id} #{status}: #{err}"
      end
      # "starting" or "processing" — keep polling
    end

    raise "Replicate prediction #{id} timed out after 20 minutes"
  end

  private def self.auth_headers : HTTP::Headers
    HTTP::Headers{
      "Authorization" => "Token #{Config.replicate_api_token}",
      "Content-Type"  => "application/json",
    }
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add src/dub/replicate_client.cr
git commit -m "feat(dub): add ReplicateClient for Whisper transcription and XTTS-v2 synthesis"
```

---

## Task 5: DeepL Client

**Files:**
- Create: `src/dub/deepl_client.cr`

DeepL Free API base URL is `https://api-free.deepl.com`. If using the paid plan, use `https://api.deepl.com`. The `DEEPL_API_KEY` for free accounts ends in `:fx`.

- [ ] **Step 1: Create file**

```crystal
# src/dub/deepl_client.cr
require "http/client"
require "uri"
require "json"

module DeepLClient
  # Use paid API endpoint if key does NOT end in ":fx"
  def self.base_url : String
    Config.deepl_api_key.ends_with?(":fx") ?
      "https://api-free.deepl.com" :
      "https://api.deepl.com"
  end

  # Translate text to the target language.
  # language: ISO 639-1 code, e.g. "ru", "fr".
  # DeepL uses uppercase codes ("RU", "FR") for target_lang.
  def self.translate(text : String, target_language : String) : String
    params = URI::Params.build do |p|
      p.add "text",        text
      p.add "target_lang", target_language.upcase
    end

    resp = HTTP::Client.post(
      "#{base_url}/v2/translate",
      headers: HTTP::Headers{
        "Authorization" => "DeepL-Auth-Key #{Config.deepl_api_key}",
        "Content-Type"  => "application/x-www-form-urlencoded",
      },
      body: params.to_s
    )

    raise "DeepL translate failed (#{resp.status_code}): #{resp.body}" unless resp.success?

    result = JSON.parse(resp.body)
    result["translations"]?
      .try(&.as_a?.try(&.first?))
      .try(&.["text"]?.try(&.as_s?)) ||
      raise "DeepL returned unexpected response: #{resp.body}"
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add src/dub/deepl_client.cr
git commit -m "feat(dub): add DeepLClient for text translation"
```

---

## Task 6: R2 Storage

**Files:**
- Create: `src/dub/r2_storage.cr`

Cloudflare R2 uses an S3-compatible API at `https://<bucket>.<account_id>.r2.cloudflarestorage.com`. Authentication uses AWS Signature Version 4. No extra shards needed — Crystal's stdlib has `OpenSSL::HMAC` and `Digest::SHA256`.

- [ ] **Step 1: Create file**

```crystal
# src/dub/r2_storage.cr
require "http/client"
require "openssl/hmac"
require "digest/sha256"
require "time"

module R2Storage
  REGION  = "auto"
  SERVICE = "s3"

  # Upload bytes to R2 and return the public URL.
  # key example: "dubbed/42/ru.mp3"
  def self.put(key : String, data : Bytes, content_type : String = "audio/mpeg") : String
    bucket   = Config.r2_bucket
    account  = Config.r2_account_id
    host     = "#{bucket}.#{account}.r2.cloudflarestorage.com"
    path     = "/#{key}"

    now      = Time.utc
    datetime = now.to_s("%Y%m%dT%H%M%SZ")
    date     = datetime[0, 8]

    payload_hash = Digest::SHA256.hexdigest(String.new(data))

    # Canonical headers (sorted alphabetically by header name)
    canon_headers  = "content-type:#{content_type}\nhost:#{host}\n" \
                     "x-amz-content-sha256:#{payload_hash}\nx-amz-date:#{datetime}\n"
    signed_headers = "content-type;host;x-amz-content-sha256;x-amz-date"

    canonical_request = [
      "PUT",
      path,
      "",  # no query string
      canon_headers,
      signed_headers,
      payload_hash,
    ].join("\n")

    scope = "#{date}/#{REGION}/#{SERVICE}/aws4_request"
    string_to_sign = [
      "AWS4-HMAC-SHA256",
      datetime,
      scope,
      Digest::SHA256.hexdigest(canonical_request),
    ].join("\n")

    # Derive signing key
    k_date    = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, "AWS4#{Config.r2_secret_access_key}", date)
    k_region  = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, k_date, REGION)
    k_service = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, k_region, SERVICE)
    k_signing = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, k_service, "aws4_request")
    signature = OpenSSL::HMAC.hexdigest(OpenSSL::Algorithm::SHA256, k_signing, string_to_sign)

    auth_header = "AWS4-HMAC-SHA256 Credential=#{Config.r2_access_key_id}/#{scope}, " \
                  "SignedHeaders=#{signed_headers}, Signature=#{signature}"

    resp = HTTP::Client.put(
      "https://#{host}#{path}",
      headers: HTTP::Headers{
        "Host"                 => host,
        "Content-Type"         => content_type,
        "x-amz-date"           => datetime,
        "x-amz-content-sha256" => payload_hash,
        "Authorization"        => auth_header,
      },
      body: String.new(data)
    )

    raise "R2 upload failed (#{resp.status_code}): #{resp.body[0, 200]}" unless resp.success?

    "#{Config.r2_public_url}/#{key}"
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add src/dub/r2_storage.cr
git commit -m "feat(dub): add R2Storage with AWS SigV4 PUT for Cloudflare R2"
```

---

## Task 7: DubJob Fiber

**Files:**
- Create: `src/dub/dub_job.cr`

The fiber chains all steps. Any exception at any step marks the job as failed. The job:
1. Marks the row as `processing`
2. Runs Whisper transcription (using the episode's `audio_url` as input — Replicate fetches it)
3. Translates via DeepL
4. Runs XTTS-v2 synthesis (using `audio_url` again as `speaker_wav` — Replicate extracts voice from it)
5. Downloads the MP3 from Replicate's CDN and uploads to R2
6. Marks as `done` and sends Telegram notification

- [ ] **Step 1: Create file**

```crystal
# src/dub/dub_job.cr
require "http/client"

module DubJob
  # Runs the full dubbing pipeline in the calling fiber.
  # Call as: spawn { DubJob.process(dub_id, episode, user) }
  def self.process(dub_id : Int64, episode : Episode, telegram_id : Int64, language : String)
    DubbedEpisode.set_processing(dub_id)

    Log.info { "DubJob[#{dub_id}]: starting pipeline for episode #{episode.id} → #{language}" }

    # Step 1: Transcribe
    Log.info { "DubJob[#{dub_id}]: transcribing with Whisper" }
    transcript = ReplicateClient.transcribe(episode.audio_url)
    Log.info { "DubJob[#{dub_id}]: transcript #{transcript.size} chars" }

    # Step 2: Translate
    Log.info { "DubJob[#{dub_id}]: translating with DeepL → #{language}" }
    translated = DeepLClient.translate(transcript, language)
    Log.info { "DubJob[#{dub_id}]: translation #{translated.size} chars" }

    # Step 3: Synthesize (pass audio_url as speaker_wav — Replicate handles large files)
    Log.info { "DubJob[#{dub_id}]: synthesizing with XTTS-v2" }
    mp3_url = ReplicateClient.synthesize(translated, episode.audio_url, language)
    Log.info { "DubJob[#{dub_id}]: synthesis done, downloading from #{mp3_url[0, 60]}..." }

    # Step 4: Download MP3 from Replicate CDN
    mp3_data = IO::Memory.new
    HTTP::Client.get(mp3_url) do |resp|
      raise "MP3 download failed: HTTP #{resp.status_code}" unless resp.success?
      IO.copy(resp.body_io, mp3_data)
    end
    Log.info { "DubJob[#{dub_id}]: downloaded #{mp3_data.size} bytes" }

    # Step 5: Upload to R2
    r2_key = "dubbed/#{episode.id}/#{language}.mp3"
    r2_url = R2Storage.put(r2_key, mp3_data.to_slice)
    Log.info { "DubJob[#{dub_id}]: uploaded to R2: #{r2_url}" }

    # Step 6: Mark done
    DubbedEpisode.set_done(dub_id, r2_url)

    # Step 7: Notify user
    BotClient.client.send_message(
      telegram_id,
      "🎙 Your dubbed episode is ready — open the player to listen in #{language.upcase}."
    )

    Log.info { "DubJob[#{dub_id}]: complete" }
  rescue ex
    Log.error { "DubJob[#{dub_id}]: failed — #{ex.message}" }
    DubbedEpisode.set_failed(dub_id, ex.message || "Unknown error")
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add src/dub/dub_job.cr
git commit -m "feat(dub): add DubJob fiber for Whisper→DeepL→XTTS-v2 pipeline"
```

---

## Task 8: Wire Requires + Startup Recovery

**Files:**
- Modify: `src/buzz_bot.cr`
- Modify: `src/models/user.cr` (add `preferred_dub_language` field)

- [ ] **Step 1: Add `preferred_dub_language` to User model**

Open `src/models/user.cr`. Find the property list and add:

```crystal
property preferred_dub_language : String?
```

Also update the `from_rs` initializer and `new(...)` call to read/pass this column. Check the existing `SELECT` query in `User.find` or `User.from_rs` and add `preferred_dub_language` to the column list and constructor.

Since the column is new (nullable), it must appear at the end of the SELECT list. Append `, preferred_dub_language` to the SELECT and add `rs.read(String?)` at the end of `from_rs`.

- [ ] **Step 2: Add requires to `src/buzz_bot.cr`**

After the existing model requires, add:

```crystal
require "./models/dubbed_episode"
require "./dub/replicate_client"
require "./dub/deepl_client"
require "./dub/r2_storage"
require "./dub/dub_job"
require "./web/routes/dub"
```

- [ ] **Step 3: Add startup recovery call**

After `AppDB.pool` is initialized (the line `Log.info { "Database connected" }`), add:

```crystal
DubbedEpisode.reset_stale_jobs
```

- [ ] **Step 4: Build to check compilation**

```bash
crystal build src/buzz_bot.cr --no-codegen 2>&1
```

Expected: no errors. Fix any type mismatches.

- [ ] **Step 5: Commit**

```bash
git add src/buzz_bot.cr src/models/user.cr
git commit -m "feat(dub): wire requires and startup stale-job reset"
```

---

## Task 9: Dub API Routes

**Files:**
- Create: `src/web/routes/dub.cr`

Three routes: POST trigger, GET poll, PUT preferred language. The language allowlist constant `DUB_LANGUAGES` is defined in `src/models/dubbed_episode.cr`.

- [ ] **Step 1: Create route file**

```crystal
# src/web/routes/dub.cr
require "json"

module Web::Routes::Dub
  def self.register
    # ── POST /episodes/:id/dub ─────────────────────────────────────────────────
    post "/episodes/:id/dub" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      unless user.subscribed?
        env.response.content_type = "application/json"
        env.response.status_code = 402
        next %({"error":"premium_required"})
      end

      episode_id = env.params.url["id"].to_i64
      episode    = Episode.find(episode_id)
      halt env, status_code: 404, response: %({"error":"not_found"}) unless episode

      body     = env.request.body.try(&.gets_to_end) || "{}"
      data     = JSON.parse(body)
      language = data["language"]?.try(&.as_s?) || ""

      unless DUB_LANGUAGES.includes?(language)
        env.response.content_type = "application/json"
        env.response.status_code = 400
        next %({"error":"unsupported_language"})
      end

      if (dur = episode.duration_sec) && dur > 3600
        env.response.content_type = "application/json"
        env.response.status_code = 400
        next %({"error":"episode_too_long"})
      end

      existing = DubbedEpisode.find(episode_id, language)

      # Return early if a live job is already in flight or result is cached
      if existing
        eff = existing.effective_status
        if eff == "processing" || eff == "pending"
          env.response.content_type = "application/json"
          next %({"id":#{existing.id},"status":"#{eff}"})
        elsif eff == "done"
          env.response.content_type = "application/json"
          next %({"id":#{existing.id},"status":"done","r2_url":#{existing.r2_url.to_json}})
        end
        # failed or expired — fall through to upsert and re-run
      end

      dub_id = DubbedEpisode.upsert_pending(episode_id, language)
      spawn { DubJob.process(dub_id, episode, user.telegram_id, language) }

      env.response.content_type = "application/json"
      env.response.status_code = 202
      %({"id":#{dub_id},"status":"pending"})
    end

    # ── GET /episodes/:id/dub/:language ────────────────────────────────────────
    get "/episodes/:id/dub/:language" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id = env.params.url["id"].to_i64
      language   = env.params.url["language"]

      unless DUB_LANGUAGES.includes?(language)
        env.response.content_type = "application/json"
        env.response.status_code = 400
        next %({"error":"unsupported_language"})
      end

      dub = DubbedEpisode.find(episode_id, language)
      halt env, status_code: 404, response: %({"error":"not_found"}) unless dub

      env.response.content_type = "application/json"
      eff = dub.effective_status
      case eff
      when "done"
        %({"status":"done","r2_url":#{dub.r2_url.to_json}})
      when "failed"
        %({"status":"failed","error":#{dub.error.to_json}})
      else
        %({"status":"#{eff}"})
      end
    end

    # ── PUT /user/dub_language ──────────────────────────────────────────────────
    put "/user/dub_language" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      unless user.subscribed?
        env.response.content_type = "application/json"
        env.response.status_code = 402
        next %({"error":"premium_required"})
      end

      body     = env.request.body.try(&.gets_to_end) || "{}"
      data     = JSON.parse(body)
      language = data["language"]?.try(&.as_s?) || ""

      unless DUB_LANGUAGES.includes?(language)
        env.response.content_type = "application/json"
        env.response.status_code = 400
        next %({"error":"unsupported_language"})
      end

      AppDB.pool.exec(
        "UPDATE users SET preferred_dub_language = $1 WHERE id = $2",
        language, user.id
      )

      env.response.status_code = 204
      nil
    end
  end
end
```

- [ ] **Step 2: Register the route module in `src/web/server.cr`**

Inside `WebServer.setup`, after `Web::Routes::Discover.register`, add:

```crystal
    Web::Routes::Dub.register
```

- [ ] **Step 3: Build**

```bash
crystal build src/buzz_bot.cr --no-codegen 2>&1
```

- [ ] **Step 4: Quick smoke-test (server must be running locally or in k8s)**

```bash
# Replace TOKEN with a valid initData string, and 123 with a real episode ID
curl -X POST http://localhost:3000/episodes/123/dub \
  -H "X-Init-Data: $INIT_DATA" \
  -H "Content-Type: application/json" \
  -d '{"language":"xx"}'
# Expected: 400 {"error":"unsupported_language"}

curl -X GET http://localhost:3000/episodes/123/dub/en \
  -H "X-Init-Data: $INIT_DATA"
# Expected: 404 {"error":"not_found"} (no dub requested yet)
```

- [ ] **Step 5: Commit**

```bash
git add src/web/routes/dub.cr src/web/server.cr
git commit -m "feat(dub): add POST/GET dub routes and PUT preferred language"
```

---

## Task 10: Extend POST /episodes/:id/send for Dubbed Audio

**Files:**
- Modify: `src/web/routes/episodes.cr` (lines 143–165)

When the request body includes `"dubbed": true`, the endpoint reads the `r2_url` from `dubbed_episodes` and passes it to `AudioSender` instead of the episode's `audio_url`.

`AudioSender.send_to_user` currently takes `(telegram_id, episode, feed)` and always uses `episode.audio_url`. We need to either: (a) add an optional `audio_url` override parameter, or (b) create a parallel path.

The cleanest approach: add an optional `override_url : String?` parameter to `send_to_user`. For existing callers that don't pass it, the episode's URL is used.

- [ ] **Step 1: Add `override_url` parameter to `AudioSender.send_to_user`**

In `src/bot/audio_sender.cr`, change the method signature from:

```crystal
def self.send_to_user(telegram_id : Int64, episode : Episode, feed : Feed?)
```

to:

```crystal
def self.send_to_user(telegram_id : Int64, episode : Episode, feed : Feed?, override_url : String? = nil)
```

Then at the top of the method body, after the signature:
- In `try_url_send`, pass `override_url || episode.audio_url` instead of `episode.audio_url`
- In `download_and_upload`, pass `override_url || episode.audio_url` instead of `episode.audio_url`

The simplest way: add one line at the top of `send_to_user`:

```crystal
# Use override URL (e.g. dubbed R2 URL) if provided
effective_url = override_url || episode.audio_url
```

Then replace uses of `episode.audio_url` with `effective_url` in `try_url_send` and `download_and_upload`. (Check both private methods use their own local `url` variable — pass `effective_url` as a parameter or use a closure.)

The most targeted change: in `try_url_send`, it reads `episode.audio_url` on line 54. Change it to use the override. Since it's a private method, add an optional parameter there too, or restructure slightly.

The cleanest minimal change is to add a struct or just thread the override URL through. Here is the exact change:

In `audio_sender.cr`, change `send_to_user` to:

```crystal
def self.send_to_user(telegram_id : Int64, episode : Episode, feed : Feed?, override_url : String? = nil)
  audio_url = override_url || episode.audio_url

  if try_url_send(telegram_id, episode, feed, audio_url)
    Log.info { "AudioSender: sent episode #{episode.id} by URL to #{telegram_id}" }
    return
  end

  size = probe_content_length(audio_url)
  if size && size > MAX_UPLOAD_SIZE
    # ... unchanged
  end

  download_and_upload(telegram_id, episode, feed, audio_url)
rescue ex
  # ... unchanged
end
```

Update `try_url_send` to accept and use `audio_url : String` instead of `episode.audio_url` directly:

```crystal
private def self.try_url_send(telegram_id : Int64, episode : Episode, feed : Feed?, audio_url : String) : Bool
  body = JSON.build do |j|
    j.object do
      j.field "chat_id", telegram_id
      j.field "audio",   audio_url    # was episode.audio_url
      # ...rest unchanged
```

Update `download_and_upload` similarly to accept `audio_url : String` and use it instead of `episode.audio_url`.

- [ ] **Step 2: Update `POST /episodes/:id/send` in `src/web/routes/episodes.cr`**

Replace the existing send handler (lines 144–165) with:

```crystal
# Send episode audio to the user's Telegram chat
post "/episodes/:id/send" do |env|
  user = Auth.current_user(env)
  halt env, status_code: 401, response: "Unauthorized" unless user

  episode_id = env.params.url["id"].to_i64
  episode = Episode.find(episode_id)
  halt env, status_code: 404, response: "Episode not found" unless episode

  feed = Feed.find(episode.feed_id)

  unless user.subscribed?
    env.response.content_type = "application/json"
    env.response.status_code = 402
    next %({"error":"premium_required"})
  end

  body   = env.request.body.try(&.gets_to_end) || "{}"
  data   = JSON.parse(body)
  dubbed = data["dubbed"]?.try(&.as_bool?) || false
  lang   = data["language"]?.try(&.as_s?)

  override_url = if dubbed && lang
    dub = DubbedEpisode.find(episode_id, lang)
    unless dub && dub.effective_status == "done"
      env.response.content_type = "application/json"
      env.response.status_code = 409
      next %({"error":"dub_not_ready"})
    end
    dub.r2_url
  end

  spawn { AudioSender.send_to_user(user.telegram_id, episode, feed, override_url) }

  env.response.content_type = "application/json"
  %({"sent":true})
end
```

- [ ] **Step 3: Build**

```bash
crystal build src/buzz_bot.cr --no-codegen 2>&1
```

- [ ] **Step 4: Commit**

```bash
git add src/bot/audio_sender.cr src/web/routes/episodes.cr
git commit -m "feat(dub): extend send endpoint to support dubbed audio via R2 URL"
```

---

## Task 11: CLJS App State + Poll Effect

**Files:**
- Modify: `src/cljs/buzz_bot/db.cljs`
- Modify: `src/cljs/buzz_bot/fx.cljs`

- [ ] **Step 1: Add `:dub` key to `default-db`**

In `src/cljs/buzz_bot/db.cljs`, add to the `default-db` map:

```clojure
   :dub {:status     nil   ;; nil | :pending | :processing | :done | :failed | :expired
         :r2-url     nil
         :error      nil
         :dub-id     nil
         :language   nil   ;; active language being dubbed
         :picker-open? false
         :preferred-language nil}
```

- [ ] **Step 2: Add `::poll-after` effect to `src/cljs/buzz_bot/fx.cljs`**

Append to `fx.cljs`:

```clojure
;; ── ::poll-after ─────────────────────────────────────────────────────────────
;; Dispatches an event after a delay (ms). Used for dub status polling.
;; Options: {:ms 5000 :dispatch [::some-event args]}

(rf/reg-fx
 ::poll-after
 (fn [{:keys [ms dispatch]}]
   (js/setTimeout #(rf/dispatch dispatch) ms)))
```

- [ ] **Step 3: Commit**

```bash
git add src/cljs/buzz_bot/db.cljs src/cljs/buzz_bot/fx.cljs
git commit -m "feat(dub): add dub state to app-db and poll-after fx"
```

---

## Task 12: CLJS Subscriptions and Events

**Files:**
- Create: `src/cljs/buzz_bot/subs/dub.cljs`
- Create: `src/cljs/buzz_bot/events/dub.cljs`
- Modify: `src/cljs/buzz_bot/core.cljs`

- [ ] **Step 1: Create `src/cljs/buzz_bot/subs/dub.cljs`**

```clojure
(ns buzz-bot.subs.dub
  (:require [re-frame.core :as rf]))

(rf/reg-sub ::dub-state    (fn [db _] (:dub db)))
(rf/reg-sub ::dub-status   :<- [::dub-state] (fn [d _] (:status d)))
(rf/reg-sub ::dub-r2-url   :<- [::dub-state] (fn [d _] (:r2-url d)))
(rf/reg-sub ::dub-error    :<- [::dub-state] (fn [d _] (:error d)))
(rf/reg-sub ::dub-language :<- [::dub-state] (fn [d _] (:language d)))
(rf/reg-sub ::dub-picker-open? :<- [::dub-state] (fn [d _] (:picker-open? d)))
(rf/reg-sub ::preferred-dub-language :<- [::dub-state] (fn [d _] (:preferred-language d)))
```

- [ ] **Step 2: Create `src/cljs/buzz_bot/events/dub.cljs`**

```clojure
(ns buzz-bot.events.dub
  (:require [re-frame.core :as rf]
            [buzz-bot.fx :as fx]))

(def dub-languages
  [{:code "en" :name "English"}
   {:code "es" :name "Spanish"}
   {:code "fr" :name "French"}
   {:code "de" :name "German"}
   {:code "it" :name "Italian"}
   {:code "pt" :name "Portuguese"}
   {:code "pl" :name "Polish"}
   {:code "tr" :name "Turkish"}
   {:code "ru" :name "Russian"}
   {:code "nl" :name "Dutch"}
   {:code "cs" :name "Czech"}
   {:code "zh" :name "Chinese"}
   {:code "ja" :name "Japanese"}
   {:code "hu" :name "Hungarian"}
   {:code "ko" :name "Korean"}])

;; Open the language picker modal.
(rf/reg-event-db
 ::open-picker
 (fn [db _]
   (assoc-in db [:dub :picker-open?] true)))

;; Close the picker without selecting.
(rf/reg-event-db
 ::close-picker
 (fn [db _]
   (assoc-in db [:dub :picker-open?] false)))

;; User selected a language: save preference, close picker, start dubbing.
(rf/reg-event-fx
 ::language-selected
 (fn [{:keys [db]} [_ episode-id lang]]
   {:db (-> db
            (assoc-in [:dub :picker-open?] false)
            (assoc-in [:dub :preferred-language] lang))
    ::fx/http-fetch {:method :put
                     :url    "/user/dub_language"
                     :body   {:language lang}
                     :on-ok  [::noop]
                     :on-err [::noop]}
    :dispatch [::request episode-id lang]}))

;; Fire the POST /episodes/:id/dub request.
(rf/reg-event-fx
 ::request
 (fn [{:keys [db]} [_ episode-id lang]]
   {:db (-> db
            (assoc-in [:dub :status] :pending)
            (assoc-in [:dub :language] lang)
            (assoc-in [:dub :r2-url] nil)
            (assoc-in [:dub :error] nil))
    ::fx/http-fetch {:method :post
                     :url    (str "/episodes/" episode-id "/dub")
                     :body   {:language lang}
                     :on-ok  [::request-ok episode-id lang]
                     :on-err [::request-err]}}))

(rf/reg-event-fx
 ::request-ok
 (fn [{:keys [db]} [_ episode-id lang resp]]
   (let [status (keyword (:status resp))]
     (cond-> {:db (-> db
                      (assoc-in [:dub :status] status)
                      (assoc-in [:dub :dub-id] (:id resp))
                      (cond-> (= status :done)
                        (assoc-in [:dub :r2-url] (:r2_url resp))))}
       (#{:pending :processing} status)
       (assoc ::fx/poll-after {:ms 5000 :dispatch [::status-tick episode-id lang]})))))

(rf/reg-event-db
 ::request-err
 (fn [db [_ err]]
   (-> db
       (assoc-in [:dub :status] :failed)
       (assoc-in [:dub :error] (str "Request failed: " err)))))

;; Poll GET /episodes/:id/dub/:language.
(rf/reg-event-fx
 ::status-tick
 (fn [_ [_ episode-id lang]]
   {::fx/http-fetch {:method :get
                     :url    (str "/episodes/" episode-id "/dub/" lang)
                     :on-ok  [::status-loaded episode-id lang]
                     :on-err [::noop]}}))

(rf/reg-event-fx
 ::status-loaded
 (fn [{:keys [db]} [_ episode-id lang resp]]
   (let [status (keyword (:status resp))]
     (cond-> {:db (-> db
                      (assoc-in [:dub :status] status)
                      (cond-> (= status :done)
                        (assoc-in [:dub :r2-url] (:r2_url resp)))
                      (cond-> (= status :failed)
                        (assoc-in [:dub :error] (:error resp))))}
       (#{:pending :processing} status)
       (assoc ::fx/poll-after {:ms 5000 :dispatch [::status-tick episode-id lang]})))))

;; Send dubbed audio to Telegram.
(rf/reg-event-fx
 ::send-telegram
 (fn [{:keys [db]} [_ episode-id]]
   (let [lang (get-in db [:dub :language])]
     {::fx/http-fetch {:method :post
                       :url    (str "/episodes/" episode-id "/send")
                       :body   {:dubbed true :language lang}
                       :on-ok  [::noop]
                       :on-err [::send-err]}})))

(rf/reg-event-db
 ::send-err
 (fn [db [_ err]]
   (assoc-in db [:dub :error] (str "Send failed: " err))))

;; Reset dub state when navigating to a new episode.
(rf/reg-event-db
 ::reset
 (fn [db _]
   (-> db
       (assoc-in [:dub :status] nil)
       (assoc-in [:dub :r2-url] nil)
       (assoc-in [:dub :error] nil)
       (assoc-in [:dub :language] nil)
       (assoc-in [:dub :dub-id] nil))))

;; No-op for fire-and-forget effects.
(rf/reg-event-db ::noop (fn [db _] db))
```

- [ ] **Step 3: Require new namespaces in `src/cljs/buzz_bot/core.cljs`**

Add to the `:require` vector in core.cljs:

```clojure
            [buzz-bot.subs.dub]
            [buzz-bot.events.dub]
```

- [ ] **Step 4: Build CLJS to check for errors**

```bash
npx shadow-cljs compile app 2>&1 | tail -20
```

Expected: `Build completed.` with no errors.

- [ ] **Step 5: Commit**

```bash
git add src/cljs/buzz_bot/subs/dub.cljs \
        src/cljs/buzz_bot/events/dub.cljs \
        src/cljs/buzz_bot/core.cljs
git commit -m "feat(dub): add CLJS dub subscriptions and events"
```

---

## Task 13: CLJS Dub View + Wire Player

**Files:**
- Create: `src/cljs/buzz_bot/views/dub.cljs`
- Modify: `src/cljs/buzz_bot/views/player.cljs`

- [ ] **Step 1: Create `src/cljs/buzz_bot/views/dub.cljs`**

```clojure
(ns buzz-bot.views.dub
  (:require [re-frame.core :as rf]
            [buzz-bot.subs.dub :as dub-subs]
            [buzz-bot.events.dub :as dub-events]))

(defn language-picker [episode-id]
  (let [preferred @(rf/subscribe [::dub-subs/preferred-dub-language])]
    [:div.dub-picker-overlay
     {:on-click #(rf/dispatch [::dub-events/close-picker])}
     [:div.dub-picker-modal
      {:on-click #(.stopPropagation %)}
      [:div.dub-picker-title "Choose dub language"]
      [:ul.dub-language-list
       (for [{:keys [code name]} dub-events/dub-languages]
         [:li.dub-language-item
          {:key      code
           :class    (when (= code preferred) "selected")
           :on-click #(rf/dispatch [::dub-events/language-selected episode-id code])}
          name
          (when (= code preferred) [:span.dub-lang-check " ✓"])])]]]))

(defn dub-panel [episode-id]
  (let [status @(rf/subscribe [::dub-subs/dub-status])
        err    @(rf/subscribe [::dub-subs/dub-error])
        lang   @(rf/subscribe [::dub-subs/dub-language])]
    [:div.dub-panel
     (case status
       nil
       [:button.btn-dub
        {:on-click #(rf/dispatch [::dub-events/open-picker])}
        "🎙 Dub Episode"]

       (:pending :processing)
       [:div.dub-status-pending
        [:span.dub-spinner "⏳"]
        " Dubbing… (this may take a few minutes)"]

       :done
       [:div.dub-done
        [:button.btn-play-dubbed
         {:on-click #(rf/dispatch [:buzz-bot.events/audio-play-url
                                   @(rf/subscribe [::dub-subs/dub-r2-url])])}
         "▶ Play Dubbed"]
        [:button.btn-send-dubbed
         {:on-click #(rf/dispatch [::dub-events/send-telegram episode-id])}
         "📨 Send Dubbed to Telegram"]]

       :failed
       [:div.dub-status-failed
        [:button.btn-dub.btn-retry
         {:on-click #(rf/dispatch [::dub-events/request episode-id lang])}
         "⚠ Dubbing failed — tap to retry"]
        (when err [:div.dub-error-detail err])]

       :expired
       [:button.btn-dub
        {:on-click #(rf/dispatch [::dub-events/open-picker])}
        "🎙 Dub Episode (expired)"]

       ;; fallback
       nil)]))
```

- [ ] **Step 2: Wire dub panel into `src/cljs/buzz_bot/views/player.cljs`**

Add the require:

```clojure
            [buzz-bot.views.dub :as dub-view]
            [buzz-bot.subs.dub :as dub-subs]
            [buzz-bot.events.dub :as dub-events]
```

Inside the `view` function, find where `is_premium` is used (currently the "Send to Telegram" button is gated on it). After the send-to-telegram button section, add:

```clojure
;; Dub panel — premium only
(when is_premium
  [dub-view/dub-panel ep-id])

;; Language picker — rendered when open
(when @(rf/subscribe [::dub-subs/dub-picker-open?])
  [dub-view/language-picker ep-id])
```

Also, dispatch `::dub-events/reset` when navigating to a new episode. Find the `::navigate` handler in events.cljs — when `view = :player`, dispatch `[::dub-events/reset]` as a side effect. Or add it to `::fetch-player` success handler. The simplest place: in `player.cljs`, in a `use-effect`-equivalent. Since this is Reagent (not React hooks), add to the component mount via `:component-did-mount` on an outer `r/create-class`, or use a `r/with-let` that dispatches on creation.

Simpler approach: dispatch `::dub-events/reset` from the existing `::navigate` event handler in `events.cljs` when `view = :player`. Add to the `::navigate` handler's `:dispatch` list.

In `events.cljs`, find the `::navigate` handler. When `view = :player`, add `:dispatch-n` (or chain) `[::dub-events/reset]`. Look for where `fetch-event` is set to `[::fetch-player ...]` and add a second dispatch.

The exact change in `events.cljs`'s `::navigate` handler — in the `cond->` map building, add:

```clojure
         (= view :player) (assoc-in [:dispatch-n] [[::dub-events/reset]])
```

Or, more precisely, since the handler already uses `:dispatch`, switch to `:dispatch-n` when there are multiple events:

```clojure
         fetch-event (assoc :dispatch-n (cond-> [fetch-event]
                                          (= view :player) (conj [::dub-events/reset])))
```

Check the existing `:dispatch` → `:dispatch-n` usage carefully to avoid breaking existing navigation.

- [ ] **Step 3: Add CSS to `public/css/app.css`**

Append:

```css
/* ── Dub feature ── */
.dub-panel            { margin-top: 12px; }
.btn-dub              { width: 100%; padding: 10px; border-radius: 8px;
                        background: var(--button-color); color: var(--button-text-color);
                        border: none; font-size: 15px; cursor: pointer; }
.btn-retry            { background: #c0392b; }
.dub-status-pending   { text-align: center; padding: 10px; color: var(--hint-color); }
.dub-spinner          { animation: spin 1.2s linear infinite; display: inline-block; }
@keyframes spin       { to { transform: rotate(360deg); } }
.dub-done             { display: flex; flex-direction: column; gap: 8px; }
.btn-play-dubbed      { width: 100%; padding: 10px; border-radius: 8px;
                        background: color-mix(in srgb, var(--button-color) 20%, transparent);
                        color: var(--text-color); border: 1px solid var(--button-color);
                        font-size: 15px; cursor: pointer; }
.btn-send-dubbed      { width: 100%; padding: 10px; border-radius: 8px;
                        background: transparent; color: var(--hint-color);
                        border: 1px solid var(--hint-color); font-size: 14px; cursor: pointer; }
.dub-status-failed    { display: flex; flex-direction: column; gap: 4px; }
.dub-error-detail     { font-size: 11px; color: #c0392b; padding: 4px 0; }

/* Language picker */
.dub-picker-overlay   { position: fixed; inset: 0; background: rgba(0,0,0,.5);
                        display: flex; align-items: flex-end; z-index: 999; }
.dub-picker-modal     { width: 100%; background: var(--bg-color);
                        border-radius: 16px 16px 0 0; padding: 16px 0 32px;
                        max-height: 70vh; overflow-y: auto; }
.dub-picker-title     { font-weight: 600; font-size: 16px;
                        padding: 0 16px 12px; border-bottom: 1px solid var(--secondary-bg); }
.dub-language-list    { list-style: none; margin: 0; padding: 0; }
.dub-language-item    { padding: 14px 16px; cursor: pointer; display: flex;
                        justify-content: space-between; }
.dub-language-item:active { background: var(--secondary-bg); }
.dub-language-item.selected { color: var(--button-color); font-weight: 500; }
```

- [ ] **Step 4: Build CLJS**

```bash
npx shadow-cljs compile app 2>&1 | tail -20
```

Expected: `Build completed.`

- [ ] **Step 5: Commit**

```bash
git add src/cljs/buzz_bot/views/dub.cljs \
        src/cljs/buzz_bot/views/player.cljs \
        src/cljs/buzz_bot/events.cljs \
        public/css/app.css
git commit -m "feat(dub): add dub panel, language picker, and player wiring"
```

---

## Task 14: Configure ENV + Deploy

**Files:**
- `k8s/` (k8s secret update)
- `k8s/deploy.sh` (run deployment)

The new ENV vars must be added to the `buzz-bot-env` k8s Secret before deploying. The k8s secret is managed with `kubectl` and **not stored in the repo** (it contains credentials).

- [ ] **Step 1: Set up Cloudflare R2**

In the Cloudflare dashboard:
1. Create a new R2 bucket named `buzz-bot-dubbed`
2. Set the bucket as **public** (enable public access)
3. Note the public URL (e.g. `https://pub-<hash>.r2.dev`)
4. Create an R2 API token with **Object Read & Write** on this bucket
5. Note: Account ID, Access Key ID, Secret Access Key

Set R2 lifecycle rule:
- Rule name: `expire-dubs`
- Prefix: `dubbed/`
- Expiration: **31 days**

- [ ] **Step 2: Set up Replicate**

Log in at replicate.com → Account → API Tokens → Create token.

- [ ] **Step 3: Set up DeepL**

Sign up at deepl.com → API → Free plan → Copy API key (ends in `:fx`).

- [ ] **Step 4: Add ENV vars to k8s secret**

```bash
# Get current secret values
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get secret buzz-bot-env -o jsonpath='{.data}' \
  | python3 -c "import sys,json,base64; d=json.load(sys.stdin); print('\n'.join(f'{k}={base64.b64decode(v).decode()}' for k,v in d.items()))" \
  > /tmp/current-env.txt

# Edit /tmp/current-env.txt to add the new vars:
# REPLICATE_API_TOKEN=r8_...
# DEEPL_API_KEY=....:fx
# R2_ACCOUNT_ID=....
# R2_ACCESS_KEY_ID=....
# R2_SECRET_ACCESS_KEY=....
# R2_BUCKET=buzz-bot-dubbed
# R2_PUBLIC_URL=https://pub-xxxx.r2.dev

# Recreate the secret
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot delete secret buzz-bot-env
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot create secret generic buzz-bot-env \
  --from-env-file=/tmp/current-env.txt

rm /tmp/current-env.txt
```

- [ ] **Step 5: Deploy**

```bash
./k8s/deploy.sh
```

- [ ] **Step 6: Verify deployment**

```bash
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get pods
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot logs -f deployment/buzz-bot --tail=30
```

Look for: `Database connected`, `DubbedEpisode: reset 0 stale jobs`, server starting line.

- [ ] **Step 7: Commit deploy artifacts**

```bash
git add -A
git commit -m "feat(dub): episode dubbing complete — Whisper/DeepL/XTTS-v2/R2 pipeline"
git push origin main
```

---

## Task 15: End-to-End Test

Manual test checklist in the Telegram Mini App (use a real premium account):

- [ ] **Test 1: Language validation**

Open any episode player. The "Dub Episode" button should be visible (premium account). Open devtools Network tab.

- [ ] **Test 2: Trigger a short episode dub**

Pick an episode under 60 minutes. Tap "Dub Episode" → pick "French". Observe:
- Network: `POST /episodes/:id/dub` → 202 `{"status":"pending"}`
- UI: spinner shown with "Dubbing…"
- Network: `GET /episodes/:id/dub/fr` polling every 5s

- [ ] **Test 3: Polling and completion**

Wait for the job to complete (expect 5-15 minutes for a typical episode). Verify:
- Final `GET` poll returns `{"status":"done","r2_url":"https://pub-...r2.dev/dubbed/.../fr.mp3"}`
- UI: "▶ Play Dubbed" and "📨 Send Dubbed to Telegram" buttons appear

- [ ] **Test 4: Play dubbed audio**

Tap "▶ Play Dubbed". Verify the audio source in the player is the R2 URL (check via browser devtools → Network → audio requests).

- [ ] **Test 5: Send dubbed to Telegram**

Tap "📨 Send Dubbed to Telegram". Verify the dubbed audio file arrives in your Telegram chat within a minute.

- [ ] **Test 6: Cached dub (re-open episode)**

Navigate away and back to the same episode. The dub UI should show `done` status immediately (no re-trigger). Verify `GET /episodes/:id/dub/fr` returns `done` on page load.

- [ ] **Test 7: Non-premium user**

Test with a non-premium account: the "Dub Episode" button should not be rendered.

- [ ] **Test 8: Duplicate dub request**

While a dub is `processing`, send a second `POST /episodes/:id/dub`. Should return `200 {"status":"processing"}` — no new fiber spawned.

- [ ] **Test 9: Server restart recovery**

While a dub is in `processing` state, restart the server pod:
```bash
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot rollout restart deployment/buzz-bot
```
After restart, check the DB: the `processing` row should be reset to `failed`. The UI should show "Dubbing failed — tap to retry" on next page load.
