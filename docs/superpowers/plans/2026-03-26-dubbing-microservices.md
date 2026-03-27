# Dubbing Microservices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the monolithic `DubJob.process` fiber into three independent Crystal microservices (transcriber, translator, synthesizer) that communicate via a PostgreSQL job queue, so each step is independently restartable, memory-bounded, and deployable.

**Architecture:** Each service is a Crystal binary that polls `dubbed_episodes` for jobs in its step, claims them atomically with `UPDATE ... WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED)`, does its work, then advances the job to the next step. The main app only creates the DB row and returns; services pick it up from the queue. No new infra — only PostgreSQL (already present).

**Tech Stack:** Crystal 1.6+, crystal-pg, Kemal (main app only), Replicate API (transcriber + synthesizer), DeepL API (translator), Cloudflare R2 (transcriber + synthesizer), Tourmaline (synthesizer for Telegram notification), k3s, Docker multi-binary image.

---

## Pipeline State Machine

```
dubbed_episodes.step:

  transcription          ← created by main app
       │ claimed by dub-transcriber (sets step=transcribing, status=processing)
  transcribing
       │ done → sets step=translation
  translation
       │ claimed by dub-translator (sets step=translating)
  translating
       │ done → sets step=synthesis
  synthesis
       │ claimed by dub-synthesizer (sets step=synthesizing)
  synthesizing
       │ done → sets step=complete, status=done
  complete

  (any step) → status=failed on error
```

`dubbed_episodes.status` remains the client-visible field (pending / processing / done / failed / expired) and is only changed at: job creation (pending), first claim (processing), completion (done), error (failed).

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `migrations/010_dubbed_episodes_pipeline.sql` | Create | Add `step`, `requester_telegram_id` columns |
| `src/models/dubbed_episode.cr` | Modify | Add step properties + atomic claim methods |
| `src/web/routes/dub.cr` | Modify | Remove `DubJob.process` spawn; pass telegram_id to upsert |
| `src/dub/dub_job.cr` | Delete | Logic moves into services |
| `src/services/dub_transcriber.cr` | Create | Poll + claim transcription jobs; Whisper + R2 |
| `src/services/dub_translator.cr` | Create | Poll + claim translation jobs; DeepL |
| `src/services/dub_synthesizer.cr` | Create | Poll + claim synthesis jobs; XTTS-v2 + R2 + Telegram notify |
| `Dockerfile` | Modify | Build 3 additional binaries; copy to runtime |
| `k8s/deploy.sh` | Modify | Copy new binaries in image |
| `k8s/dub-transcriber-deployment.yaml` | Create | k3s Deployment for transcriber |
| `k8s/dub-translator-deployment.yaml` | Create | k3s Deployment for translator |
| `k8s/dub-synthesizer-deployment.yaml` | Create | k3s Deployment for synthesizer |

---

## Task 1: Database Migration

**Files:**
- Create: `migrations/010_dubbed_episodes_pipeline.sql`

- [ ] **Step 1: Write migration**

```sql
-- migrations/010_dubbed_episodes_pipeline.sql
ALTER TABLE dubbed_episodes
  ADD COLUMN IF NOT EXISTS step VARCHAR(30) NOT NULL DEFAULT 'transcription',
  ADD COLUMN IF NOT EXISTS requester_telegram_id BIGINT;

-- Backfill existing rows
UPDATE dubbed_episodes SET step = 'complete' WHERE status = 'done';
UPDATE dubbed_episodes SET step = 'transcription' WHERE status IN ('pending', 'processing', 'failed');

-- Index for service polling queries
CREATE INDEX IF NOT EXISTS idx_dubbed_episodes_step ON dubbed_episodes (step) WHERE status NOT IN ('done', 'failed', 'expired');
```

- [ ] **Step 2: Apply migration**

```sh
nix-shell -p postgresql --run "psql 'postgresql://neondb_owner:npg_XjP89FtzZGBR@ep-wild-breeze-agvn6pj4-pooler.c-2.eu-central-1.aws.neon.tech/neondb?sslmode=require' -f migrations/010_dubbed_episodes_pipeline.sql"
```

Expected output: `ALTER TABLE`, `UPDATE`, `UPDATE`, `CREATE INDEX`

- [ ] **Step 3: Verify**

```sh
nix-shell -p postgresql --run "psql 'postgresql://neondb_owner:npg_XjP89FtzZGBR@ep-wild-breeze-agvn6pj4-pooler.c-2.eu-central-1.aws.neon.tech/neondb?sslmode=require' -c '\d dubbed_episodes'"
```

Confirm `step` and `requester_telegram_id` columns exist.

- [ ] **Step 4: Commit**

```sh
git add migrations/010_dubbed_episodes_pipeline.sql
git commit -m "feat(dub): add pipeline step tracking columns to dubbed_episodes"
```

---

## Task 2: Update DubbedEpisode Model

**Files:**
- Modify: `src/models/dubbed_episode.cr`

The model needs: `step` and `requester_telegram_id` properties, updated `from_rs`/`find` (now reads 11 columns), updated `upsert_pending` (accepts `requester_telegram_id`, resets `step`), new atomic claim methods, new step-advance methods, and a startup reset helper.

- [ ] **Step 1: Update properties and from_rs**

Replace the struct definition and `from_rs` with:

```crystal
struct DubbedEpisode
  include JSON::Serializable

  property id                   : Int64
  property episode_id           : Int64
  property language             : String
  property status               : String
  property step                 : String
  property r2_url               : String?
  property translation          : String?
  property error                : String?
  property expires_at           : Time?
  property created_at           : Time
  property requester_telegram_id : Int64?

  def initialize(@id, @episode_id, @language, @status, @step, @r2_url,
                 @translation, @error, @expires_at, @created_at, @requester_telegram_id)
  end

  def expired? : Bool
    status == "done" && (expires_at.try { |t| t < Time.utc } || false)
  end

  def effective_status : String
    expired? ? "expired" : status
  end

  private def self.from_rs(rs) : DubbedEpisode
    new(
      rs.read(Int64),   # id
      rs.read(Int64),   # episode_id
      rs.read(String),  # language
      rs.read(String),  # status
      rs.read(String),  # step
      rs.read(String?), # r2_url
      rs.read(String?), # translation
      rs.read(String?), # error
      rs.read(Time?),   # expires_at
      rs.read(Time),    # created_at
      rs.read(Int64?)   # requester_telegram_id
    )
  end
```

- [ ] **Step 2: Update `find` SELECT (add step, requester_telegram_id)**

```crystal
  def self.find(episode_id : Int64, language : String) : DubbedEpisode?
    AppDB.pool.query_one?(
      <<-SQL,
        SELECT id, episode_id, language, status, step, r2_url, translation,
               error, expires_at, created_at, requester_telegram_id
        FROM dubbed_episodes
        WHERE episode_id = $1 AND language = $2
      SQL
      episode_id, language
    ) { |rs| from_rs(rs) }
  end
```

- [ ] **Step 3: Update `upsert_pending` to accept telegram_id and reset step**

```crystal
  def self.upsert_pending(episode_id : Int64, language : String, requester_telegram_id : Int64) : Int64
    AppDB.pool.query_one(
      <<-SQL,
        INSERT INTO dubbed_episodes (episode_id, language, status, step, requester_telegram_id)
        VALUES ($1, $2, 'pending', 'transcription', $3)
        ON CONFLICT (episode_id, language) DO UPDATE
          SET status                = 'pending',
              step                  = 'transcription',
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

- [ ] **Step 4: Add atomic claim methods (one per service)**

Each method atomically claims one pending job and marks it as active using a single UPDATE with a subquery — no separate transaction needed.

```crystal
  # Claimed by dub-transcriber.  Returns {dub_id, episode_id, language} or nil.
  def self.claim_for_transcription : {Int64, Int64, String}?
    AppDB.pool.query_one?(
      <<-SQL,
        UPDATE dubbed_episodes
        SET step = 'transcribing', status = 'processing'
        WHERE id = (
          SELECT id FROM dubbed_episodes
          WHERE step = 'transcription'
          ORDER BY created_at
          LIMIT 1
          FOR UPDATE SKIP LOCKED
        )
        RETURNING id, episode_id, language
      SQL
      as: {Int64, Int64, String}
    )
  end

  # Claimed by dub-translator.  Returns {dub_id, episode_id, language} or nil.
  def self.claim_for_translation : {Int64, Int64, String}?
    AppDB.pool.query_one?(
      <<-SQL,
        UPDATE dubbed_episodes
        SET step = 'translating'
        WHERE id = (
          SELECT id FROM dubbed_episodes
          WHERE step = 'translation'
          ORDER BY created_at
          LIMIT 1
          FOR UPDATE SKIP LOCKED
        )
        RETURNING id, episode_id, language
      SQL
      as: {Int64, Int64, String}
    )
  end

  # Claimed by dub-synthesizer.  Returns {dub_id, episode_id, language, translation, requester_telegram_id} or nil.
  def self.claim_for_synthesis : {Int64, Int64, String, String, Int64?}?
    AppDB.pool.query_one?(
      <<-SQL,
        UPDATE dubbed_episodes
        SET step = 'synthesizing'
        WHERE id = (
          SELECT id FROM dubbed_episodes
          WHERE step = 'synthesis'
          ORDER BY created_at
          LIMIT 1
          FOR UPDATE SKIP LOCKED
        )
        RETURNING id, episode_id, language, translation, requester_telegram_id
      SQL
      as: {Int64, Int64, String, String, Int64?}
    )
  end
```

- [ ] **Step 5: Add step-advance and set_complete methods**

```crystal
  def self.advance_to_translation(id : Int64)
    AppDB.pool.exec(
      "UPDATE dubbed_episodes SET step = 'translation' WHERE id = $1", id
    )
  end

  def self.advance_to_synthesis(id : Int64, translation : String)
    AppDB.pool.exec(
      "UPDATE dubbed_episodes SET step = 'synthesis', translation = $2 WHERE id = $1",
      id, translation
    )
  end

  def self.set_complete(id : Int64, r2_url : String)
    AppDB.pool.exec(
      <<-SQL,
        UPDATE dubbed_episodes
        SET step = 'complete', status = 'done', r2_url = $2,
            expires_at = NOW() + INTERVAL '29 days'
        WHERE id = $1
      SQL
      id, r2_url
    )
  end
```

- [ ] **Step 6: Add startup reset helper**

Called by each service on boot to reclaim jobs that were in-flight when the service last crashed.

```crystal
  # On service start: reset in-flight jobs back to the claimable step.
  # E.g. reset_in_flight("transcribing", "transcription")
  def self.reset_in_flight(from_step : String, to_step : String)
    n = AppDB.pool.exec(
      "UPDATE dubbed_episodes SET step = $1 WHERE step = $2",
      to_step, from_step
    ).rows_affected
    Log.info { "DubbedEpisode: reset #{n} stale '#{from_step}' jobs to '#{to_step}'" } if n > 0
  end
```

- [ ] **Step 7: Update `statuses_for_episode` to include new columns**

The SELECT already works; no change needed since it only reads `language, status, r2_url, translation, expires_at`. ✓

- [ ] **Step 8: Update `set_done` → rename to be consistent**

`set_done` is called nowhere now (replaced by `set_complete`). Remove it, or keep for compatibility — remove it since `set_complete` replaces it and has a different signature.

Remove `set_done` method. Keep `set_failed`, `set_processing`, `reset_stale_jobs` (renamed below).

Update `reset_stale_jobs` to also reset stuck step values:

```crystal
  def self.reset_stale_jobs
    count = AppDB.pool.exec(
      <<-SQL
        UPDATE dubbed_episodes
        SET status = 'failed', error = 'Server restarted',
            step   = 'transcription'
        WHERE status IN ('pending', 'processing')
          AND step NOT IN ('complete')
      SQL
    ).rows_affected
    Log.info { "DubbedEpisode: reset #{count} stale jobs to failed" } if count > 0
  end
```

- [ ] **Step 9: Verify the file compiles (build check)**

```sh
crystal build src/buzz_bot.cr --no-codegen 2>&1 | head -20
```

Expected: no errors.

- [ ] **Step 10: Commit**

```sh
git add src/models/dubbed_episode.cr
git commit -m "feat(dub): add step tracking and atomic claim methods to DubbedEpisode"
```

---

## Task 3: Update Main App Dub Route

**Files:**
- Modify: `src/web/routes/dub.cr`

Remove the `spawn { DubJob.process(...) }` call. The main app now only creates the DB row; services do the work. Also pass `user.telegram_id` to `upsert_pending`.

- [ ] **Step 1: Update the POST route — remove DubJob spawn, pass telegram_id**

Find the section in `src/web/routes/dub.cr` that calls `DubJob.process` (at the bottom of the POST handler, after `DubbedEpisode.upsert_pending`). Replace it:

**Before (approximate):**
```crystal
dub_id = DubbedEpisode.upsert_pending(episode_id, language)
spawn { DubJob.process(dub_id, episode, user.telegram_id, language) }
env.response.content_type = "application/json"
next %({"id":#{dub_id},"status":"pending"})
```

**After:**
```crystal
dub_id = DubbedEpisode.upsert_pending(episode_id, language, user.telegram_id)
env.response.content_type = "application/json"
next %({"id":#{dub_id},"status":"pending"})
```

- [ ] **Step 2: Remove the `require` for dub_job if present**

Check the top of `src/web/routes/dub.cr` for `require "../dub/dub_job"` and remove it if present.

- [ ] **Step 3: Build check**

```sh
crystal build src/buzz_bot.cr --no-codegen 2>&1 | head -20
```

Expected: no errors.

- [ ] **Step 4: Delete `src/dub/dub_job.cr`**

The logic is now split across the three service files. Archive first if desired:

```sh
git rm src/dub/dub_job.cr
```

- [ ] **Step 5: Commit**

```sh
git add src/web/routes/dub.cr
git commit -m "feat(dub): remove DubJob.process spawn — services pick up from DB queue"
```

---

## Task 4: Implement dub-transcriber Service

**Files:**
- Create: `src/services/dub_transcriber.cr`

This service claims `step='transcription'` jobs, downloads the episode audio to R2, calls Whisper via Replicate, saves transcript + detected language, then advances to `step='translation'`. If the episode already has a transcript, skips Whisper entirely.

- [ ] **Step 1: Write the service file**

```crystal
# src/services/dub_transcriber.cr
require "http/client"
require "../config"
require "../db"
require "../models/episode"
require "../models/dubbed_episode"
require "../dub/replicate_client"
require "../dub/r2_storage"

Log.setup_from_env

Log.info { "DubTranscriber: starting" }
DubbedEpisode.reset_in_flight("transcribing", "transcription")

loop do
  if (job = DubbedEpisode.claim_for_transcription)
    dub_id, episode_id, language = job
    process(dub_id, episode_id, language)
    sleep 100.milliseconds
  else
    sleep 5.seconds
  end
end

def process(dub_id : Int64, episode_id : Int64, language : String)
  Log.info { "DubTranscriber[#{dub_id}]: claimed (episode #{episode_id} → #{language})" }

  transcript = Episode.transcript(episode_id)
  if transcript
    Log.info { "DubTranscriber[#{dub_id}]: transcript cached (#{transcript.size} chars), skipping Whisper" }
  else
    episode = Episode.find(episode_id)
    raise "Episode #{episode_id} not found" unless episode

    Log.info { "DubTranscriber[#{dub_id}]: downloading full audio for Whisper" }
    audio_r2_url = upload_full_audio(dub_id, episode.audio_url)

    Log.info { "DubTranscriber[#{dub_id}]: transcribing with Whisper" }
    transcript, detected_lang = ReplicateClient.transcribe(audio_r2_url)

    Episode.save_transcript(episode_id, transcript)
    if detected_lang
      Episode.save_original_language(episode_id, detected_lang)
      Log.info { "DubTranscriber[#{dub_id}]: detected language: #{detected_lang}" }
    end
    Log.info { "DubTranscriber[#{dub_id}]: transcript saved (#{transcript.size} chars)" }
  end

  DubbedEpisode.advance_to_translation(dub_id)
  Log.info { "DubTranscriber[#{dub_id}]: advanced to translation" }
rescue ex
  Log.error { "DubTranscriber[#{dub_id}]: failed — #{ex.message}" }
  DubbedEpisode.set_failed(dub_id, ex.message || "Unknown error")
end

# Download full episode audio (following redirects) and upload to R2 temp storage.
# Returns the public R2 URL for Whisper to fetch.
private def upload_full_audio(dub_id : Int64, audio_url : String) : String
  buf = IO::Memory.new
  url = audio_url
  redirects = 0
  done = false
  until done
    HTTP::Client.get(url) do |resp|
      if resp.status.redirection?
        redirects += 1
        raise "Too many redirects fetching full audio" if redirects > 5
        url = resp.headers["Location"]? || raise "Full audio redirect missing Location header"
      else
        raise "Full audio download failed: HTTP #{resp.status_code}" unless resp.success?
        IO.copy(resp.body_io, buf)
        done = true
      end
    end
  end
  R2Storage.put("tmp/audio/#{dub_id}.mp3", buf.to_slice)
end
```

- [ ] **Step 2: Build check**

```sh
crystal build src/services/dub_transcriber.cr --no-codegen 2>&1 | head -20
```

Expected: no errors.

- [ ] **Step 3: Commit**

```sh
git add src/services/dub_transcriber.cr
git commit -m "feat(dub): implement dub-transcriber service"
```

---

## Task 5: Implement dub-translator Service

**Files:**
- Create: `src/services/dub_translator.cr`

Claims `step='translation'` jobs, reads transcript from `episodes.transcript`, calls DeepL, saves translation to `dubbed_episodes.translation`, advances to `step='synthesis'`.

- [ ] **Step 1: Write the service file**

```crystal
# src/services/dub_translator.cr
require "../config"
require "../db"
require "../models/episode"
require "../models/dubbed_episode"
require "../dub/deepl_client"

Log.setup_from_env

Log.info { "DubTranslator: starting" }
DubbedEpisode.reset_in_flight("translating", "translation")

loop do
  if (job = DubbedEpisode.claim_for_translation)
    dub_id, episode_id, language = job
    process(dub_id, episode_id, language)
    sleep 100.milliseconds
  else
    sleep 5.seconds
  end
end

def process(dub_id : Int64, episode_id : Int64, language : String)
  Log.info { "DubTranslator[#{dub_id}]: claimed (episode #{episode_id} → #{language})" }

  transcript = Episode.transcript(episode_id)
  raise "No transcript for episode #{episode_id}" unless transcript

  Log.info { "DubTranslator[#{dub_id}]: translating #{transcript.size} chars to #{language}" }
  translation = DeepLClient.translate(transcript, language)
  Log.info { "DubTranslator[#{dub_id}]: translation #{translation.size} chars" }

  DubbedEpisode.advance_to_synthesis(dub_id, translation)
  Log.info { "DubTranslator[#{dub_id}]: advanced to synthesis" }
rescue ex
  Log.error { "DubTranslator[#{dub_id}]: failed — #{ex.message}" }
  DubbedEpisode.set_failed(dub_id, ex.message || "Unknown error")
end
```

- [ ] **Step 2: Build check**

```sh
crystal build src/services/dub_translator.cr --no-codegen 2>&1 | head -20
```

Expected: no errors.

- [ ] **Step 3: Commit**

```sh
git add src/services/dub_translator.cr
git commit -m "feat(dub): implement dub-translator service"
```

---

## Task 6: Implement dub-synthesizer Service

**Files:**
- Create: `src/services/dub_synthesizer.cr`

Claims `step='synthesis'` jobs, downloads a 3 MB voice clip from the episode audio and uploads to R2, calls XTTS-v2 via Replicate with the translated text, downloads the MP3 result, uploads to R2 as the final dubbed file, sets the job to `done`, and sends a Telegram notification to the requester.

- [ ] **Step 1: Write the service file**

```crystal
# src/services/dub_synthesizer.cr
require "http/client"
require "../config"
require "../db"
require "../models/episode"
require "../models/dubbed_episode"
require "../dub/replicate_client"
require "../dub/r2_storage"
require "../bot/client"

Log.setup_from_env

Log.info { "DubSynthesizer: starting" }
BotClient.register  # initialize Telegram client (no webhook — just send)
DubbedEpisode.reset_in_flight("synthesizing", "synthesis")

loop do
  if (job = DubbedEpisode.claim_for_synthesis)
    dub_id, episode_id, language, translation, requester_tg_id = job
    process(dub_id, episode_id, language, translation, requester_tg_id)
    sleep 100.milliseconds
  else
    sleep 5.seconds
  end
end

def process(dub_id : Int64, episode_id : Int64, language : String,
            translation : String, requester_tg_id : Int64?)
  Log.info { "DubSynthesizer[#{dub_id}]: claimed (episode #{episode_id} → #{language})" }

  episode = Episode.find(episode_id)
  raise "Episode #{episode_id} not found" unless episode

  Log.info { "DubSynthesizer[#{dub_id}]: extracting voice clip" }
  speaker_wav = upload_voice_clip(dub_id, episode.audio_url)

  Log.info { "DubSynthesizer[#{dub_id}]: synthesizing with XTTS-v2" }
  mp3_url = ReplicateClient.synthesize(translation, speaker_wav, language)

  Log.info { "DubSynthesizer[#{dub_id}]: downloading MP3" }
  mp3_data = IO::Memory.new
  HTTP::Client.get(mp3_url) do |resp|
    raise "MP3 download failed: HTTP #{resp.status_code}" unless resp.success?
    IO.copy(resp.body_io, mp3_data)
  end
  Log.info { "DubSynthesizer[#{dub_id}]: downloaded #{mp3_data.size} bytes" }

  r2_key = "dubbed/#{episode_id}/#{language}.mp3"
  r2_url  = R2Storage.put(r2_key, mp3_data.to_slice)
  Log.info { "DubSynthesizer[#{dub_id}]: uploaded to R2: #{r2_url}" }

  DubbedEpisode.set_complete(dub_id, r2_url)
  Log.info { "DubSynthesizer[#{dub_id}]: complete" }

  if requester_tg_id
    BotClient.client.send_message(
      requester_tg_id,
      "🎙 Your dubbed episode is ready — open the player to listen in #{language.upcase}."
    )
  end
rescue ex
  Log.error { "DubSynthesizer[#{dub_id}]: failed — #{ex.message}" }
  DubbedEpisode.set_failed(dub_id, ex.message || "Unknown error")
end

# Download first 3 MB of episode audio (voice sample for XTTS-v2), upload to R2.
private def upload_voice_clip(dub_id : Int64, audio_url : String) : String
  clip = IO::Memory.new
  url = audio_url
  redirects = 0
  done = false
  until done
    HTTP::Client.get(url, headers: HTTP::Headers{"Range" => "bytes=0-3145727"}) do |resp|
      if resp.status.redirection?
        redirects += 1
        raise "Too many redirects fetching voice clip" if redirects > 5
        url = resp.headers["Location"]? || raise "Voice clip redirect missing Location header"
      else
        raise "Voice clip download failed: HTTP #{resp.status_code}" unless resp.success? || resp.status_code == 206
        IO.copy(resp.body_io, clip, 3_145_728)
        done = true
      end
    end
  end
  R2Storage.put("tmp/voice/#{dub_id}.mp3", clip.to_slice)
end
```

- [ ] **Step 2: Check `BotClient.register` API**

Look at `src/bot/client.cr` to confirm the method name for initializing the client without starting a webhook server. If it's named differently (e.g. `BotClient.start` or the client is initialized lazily), adjust accordingly. The synthesizer only needs to *send* messages, not register a webhook.

- [ ] **Step 3: Build check**

```sh
crystal build src/services/dub_synthesizer.cr --no-codegen 2>&1 | head -20
```

Expected: no errors. Adjust BotClient initialization if needed.

- [ ] **Step 4: Commit**

```sh
git add src/services/dub_synthesizer.cr
git commit -m "feat(dub): implement dub-synthesizer service"
```

---

## Task 7: Dockerfile — Build Three Additional Binaries

**Files:**
- Modify: `Dockerfile`

- [ ] **Step 1: Add build steps for the three service binaries**

In the builder stage (after the existing `crystal build src/buzz_bot.cr` line), add:

```dockerfile
RUN crystal build --release --static src/services/dub_transcriber.cr -o dub-transcriber
RUN crystal build --release --static src/services/dub_translator.cr   -o dub-translator
RUN crystal build --release --static src/services/dub_synthesizer.cr  -o dub-synthesizer
```

- [ ] **Step 2: Copy binaries to runtime image**

In the runtime stage (after `COPY --from=builder /app/buzz-bot ./buzz-bot`), add:

```dockerfile
COPY --from=builder /app/dub-transcriber  ./dub-transcriber
COPY --from=builder /app/dub-translator   ./dub-translator
COPY --from=builder /app/dub-synthesizer  ./dub-synthesizer
```

- [ ] **Step 3: Test build locally**

```sh
docker build -t buzz-bot:test .
docker run --rm buzz-bot:test ls -la /app/dub-*
```

Expected: three binaries listed.

- [ ] **Step 4: Commit**

```sh
git add Dockerfile
git commit -m "feat(dub): build service binaries in Dockerfile"
```

---

## Task 8: k3s Deployments for Services

**Files:**
- Create: `k8s/dub-transcriber-deployment.yaml`
- Create: `k8s/dub-translator-deployment.yaml`
- Create: `k8s/dub-synthesizer-deployment.yaml`
- Modify: `k8s/deploy.sh`

Each service runs the same Docker image as the main app but with a different command. They use the same `buzz-bot-env` secret for DB and API credentials. Low memory limits (128Mi) — they don't buffer full audio files in memory (they stream to R2).

- [ ] **Step 1: Create dub-transcriber-deployment.yaml**

```yaml
# k8s/dub-transcriber-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dub-transcriber
  namespace: buzz-bot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dub-transcriber
  template:
    metadata:
      labels:
        app: dub-transcriber
    spec:
      containers:
        - name: dub-transcriber
          image: ghcr.io/watchcat/buzz-bot:latest
          imagePullPolicy: IfNotPresent
          command: ["/app/dub-transcriber"]
          envFrom:
            - secretRef:
                name: buzz-bot-env
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 128Mi
```

- [ ] **Step 2: Create dub-translator-deployment.yaml**

```yaml
# k8s/dub-translator-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dub-translator
  namespace: buzz-bot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dub-translator
  template:
    metadata:
      labels:
        app: dub-translator
    spec:
      containers:
        - name: dub-translator
          image: ghcr.io/watchcat/buzz-bot:latest
          imagePullPolicy: IfNotPresent
          command: ["/app/dub-translator"]
          envFrom:
            - secretRef:
                name: buzz-bot-env
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
```

- [ ] **Step 3: Create dub-synthesizer-deployment.yaml**

```yaml
# k8s/dub-synthesizer-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dub-synthesizer
  namespace: buzz-bot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dub-synthesizer
  template:
    metadata:
      labels:
        app: dub-synthesizer
    spec:
      containers:
        - name: dub-synthesizer
          image: ghcr.io/watchcat/buzz-bot:latest
          imagePullPolicy: IfNotPresent
          command: ["/app/dub-synthesizer"]
          envFrom:
            - secretRef:
                name: buzz-bot-env
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 128Mi
```

- [ ] **Step 4: Update deploy.sh to apply service deployments**

Add after the main `kubectl rollout` section:

```sh
echo "==> Deploying dub services"
kubectl apply -f k8s/dub-transcriber-deployment.yaml \
              -f k8s/dub-translator-deployment.yaml \
              -f k8s/dub-synthesizer-deployment.yaml \
  --kubeconfig k8s/kubeconfig
kubectl rollout restart deployment/dub-transcriber deployment/dub-translator deployment/dub-synthesizer \
  -n buzz-bot --kubeconfig k8s/kubeconfig
```

- [ ] **Step 5: Commit**

```sh
git add k8s/dub-transcriber-deployment.yaml k8s/dub-translator-deployment.yaml \
        k8s/dub-synthesizer-deployment.yaml k8s/deploy.sh
git commit -m "feat(dub): k3s deployments for transcriber, translator, synthesizer services"
```

---

## Task 9: Deploy and Verify End-to-End

- [ ] **Step 1: Deploy everything**

```sh
bash k8s/deploy.sh
```

Expected: main app + 3 service deployments rolled out.

- [ ] **Step 2: Confirm all pods running**

```sh
nix-shell -p kubectl --run "KUBECONFIG=k8s/kubeconfig kubectl get pods -n buzz-bot"
```

Expected: 4 pods running (buzz-bot, dub-transcriber, dub-translator, dub-synthesizer).

- [ ] **Step 3: Check service startup logs**

```sh
nix-shell -p kubectl --run "KUBECONFIG=k8s/kubeconfig kubectl logs -n buzz-bot deploy/dub-transcriber --tail=10"
nix-shell -p kubectl --run "KUBECONFIG=k8s/kubeconfig kubectl logs -n buzz-bot deploy/dub-translator --tail=10"
nix-shell -p kubectl --run "KUBECONFIG=k8s/kubeconfig kubectl logs -n buzz-bot deploy/dub-synthesizer --tail=10"
```

Expected: each shows "DubXxx: starting" and "reset N stale jobs" (N may be 0).

- [ ] **Step 4: Trigger a dub from the UI**

Open the app, open any episode player, tap a language chip. Watch service logs:

```sh
nix-shell -p kubectl --run "KUBECONFIG=k8s/kubeconfig kubectl logs -n buzz-bot deploy/dub-transcriber -f"
# In parallel:
nix-shell -p kubectl --run "KUBECONFIG=k8s/kubeconfig kubectl logs -n buzz-bot deploy/dub-translator -f"
nix-shell -p kubectl --run "KUBECONFIG=k8s/kubeconfig kubectl logs -n buzz-bot deploy/dub-synthesizer -f"
```

Expected sequence in logs:
1. `DubTranscriber[N]: claimed` → `transcript saved` → `advanced to translation`
2. `DubTranslator[N]: claimed` → `translation X chars` → `advanced to synthesis`
3. `DubSynthesizer[N]: claimed` → `uploaded to R2` → `complete`

- [ ] **Step 5: Verify UI shows progress and final result**

- Language chip should pulse (pending/processing) while in progress
- Chip should turn highlighted (done) when complete
- Telegram notification should arrive

- [ ] **Step 6: Commit final state**

```sh
git add -A
git commit -m "feat(dub): microservices pipeline — transcriber, translator, synthesizer via PG queue"
git push origin main
```

---

## Notes

**Memory budget after refactor (single Hetzner cpx22, 4 GB RAM):**

| Pod | Limit | Reason |
|-----|-------|--------|
| buzz-bot | 512Mi | Handles AudioSender multipart upload |
| dub-transcriber | 128Mi | Buffers full audio in memory for R2 upload — largest allocation |
| dub-translator | 64Mi | Just text strings |
| dub-synthesizer | 128Mi | Buffers voice clip (3 MB) + MP3 result |

Total headroom: ~3 GB free for OS, DB connections, Telegram API pod.

**Retry behaviour:** A failed step retries from that step (transcript cache avoids re-running Whisper). On service restart, `reset_in_flight` makes in-progress jobs claimable again. The existing `reset_stale_jobs` in the main app (run at startup) resets stuck jobs to failed so the user can retry from the UI.

**Future: PG LISTEN/NOTIFY** — Replace the 5-second idle poll with `LISTEN` on a dedicated PG connection per service. The `claim_for_X` methods emit `SELECT pg_notify('dub_translation', dub_id::text)` after advancing. This cuts latency between steps from ≤5 s to <100 ms. Not required for correctness; add when step latency matters.
