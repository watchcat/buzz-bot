# Proxy stream-through OOM fix — design

Date: 2026-05-20
Status: approved (pre-implementation)
Repo: buzz-bot (`src/web/routes/app.cr`, `src/web/routes/episodes.cr`)
Related: ops commit `95c8652` (the 512Mi → 1Gi memory bump being stop-gapped)

## Problem

The pod was `OOMKilled` (exit 137, CrashLoop) under concurrent proxy traffic.
Stop-gap was `k8s/deployment.yaml: memory: 512Mi → 1Gi`. Two endpoints are
implicated; the real fix is to bound their RAM footprint so it does not grow
with response-body size or concurrency.

### `/img-proxy` (`src/web/routes/app.cr:37`)

Currently:

1. `HTTP::Client.get(url)` (no block form) — **buffers the entire response body
   into memory** before returning.
2. `resp.body.to_slice.dup` — a second full copy, transiently.
3. An in-process cache (`CACHE = {} of String => {Bytes, String}`) capped at
   500 entries by count, evicted FIFO via `CACHE.delete(CACHE.first_key)`,
   **with no byte cap**. The comment claims ~50 MB at ~100 KB per image; actual
   podcast artwork is regularly 1–3 MB JPEG/PNG, so worst-case cache footprint
   is 500–1500 MB. FIFO (not LRU) means hot items get evicted just as fast as
   cold ones under URL churn.

Per-request RAM is unbounded; long-lived cache RAM is unbounded. This is the
dominant OOM source.

### `/episodes/:id/audio_proxy` (`src/web/routes/episodes.cr:198`)

Already streams via `IO.copy(resp.body_io, env.response, 128 * 1024)` — RAM
per in-flight request is ~128 KB plus connection state. The risk here is
**unbounded concurrency**: when an upstream CDN stalls, fibers pile up
indefinitely. The commit message on the memory bump specifically calls out
"img-proxy/audio-proxy stream-through buffers (slow upstreams)" as a cause.

Audio-proxy is **not** in the listening path: `episodes.cr:189` documents that
"the audio element plays from the direct CDN URL"; the proxy exists only for
the service worker's background "save for offline" flow that populates the
`buzz-audio-v1` cache. So the cap governs offline-download fan-out, not
simultaneous listeners.

## Goal

Make per-request and steady-state RAM bound by a small constant rather than by
response body size or concurrency level, so the pod cannot OOM under proxy
traffic. After observing two days of steady-state RSS well below 512 MB, file
a follow-up to revert `1Gi → 512Mi` (out of scope of this spec).

## Non-goals

- Reverting `1Gi → 512Mi` in `k8s/deployment.yaml` (post-observation cleanup).
- Pre-fetch + resize podcast artwork at RSS-ingest time (deferred long-term
  optimisation; out of scope here).
- Range-request support on `/audio_proxy` (not needed; listening bypasses the
  proxy).
- Prometheus/metrics endpoints for in-flight counts. Log lines suffice for now.
- Any client-side change. The CLJS `img-proxy` wrapper and the SW download
  flow stay as-is.

## Locked decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Scope | Both endpoints in one PR; deployment.yaml revert deferred. |
| img-proxy cache | **Drop entirely.** Rely on `Cache-Control: public, max-age=86400, immutable` + browser cache + SW shell cache. |
| audio-proxy cap | Global 64 + per-upstream-host 16. 503 over cap with `Retry-After: 2`. |
| img-proxy cap | None. With stream-through (~50 KB/fiber), concurrency is not the OOM lever. |
| img-proxy size ceiling | 5 MB — abort with 502 if Content-Length declares more, or if streamed bytes exceed the cap. Defends against HTML error pages mis-served as images and accidental huge artwork. |
| audio-proxy size ceiling | None. Real episodes are 10–300 MB; rely on read-timeout to kill stuck streams. |
| Implementation shape | Approach A — single shared `src/web/proxy_helpers.cr` module exposing `ProxyLimiter` and `ProxyStreamer.stream_through`. Routes wire them in. |

## Architecture

Three units with clear boundaries:

| Unit | Responsibility | File |
|---|---|---|
| `ProxyHelpers::ProxyLimiter` | Channel-based semaphore: global cap + per-host sub-cap. Non-blocking acquire raises `CapExceeded` if no slot. Releases on block exit (including exceptions). | `src/web/proxy_helpers.cr` (new) |
| `ProxyHelpers::ProxyStreamer.stream_through` | `HTTP::Client.get(url) do |resp| ... end` with chunked `IO.copy`, optional `max_bytes` ceiling, `on_headers` callback to let the caller write response headers before bytes flow. Raises `TooLarge` if the ceiling is exceeded. | same file |
| Route handlers | Wire helpers into the request lifecycle: auth, header forwarding, error → status mapping, Kemal-specific `env.response.close` semantics for chunked streams. | `src/web/routes/app.cr`, `src/web/routes/episodes.cr` |

The two helpers communicate through narrow interfaces; each can be tested in
isolation against a local `HTTP::Server` fixture without touching Kemal.

### `ProxyLimiter` semantics

```crystal
class ProxyHelpers::ProxyLimiter
  class CapExceeded < Exception; end

  def initialize(@global_cap : Int32, @per_host_cap : Int32)
  def with_slot(host : String, & : -> T) : T forall T  # yields or raises CapExceeded
end
```

Two acquisitions per call: first the global slot, then the per-host slot. If
the host slot fails after the global succeeded, release the global before
raising. Release order on normal exit is host then global. Implemented as
counter + mutex (simpler and more obviously correct than nested non-blocking
`Channel#send_select`); the implementation file will document why.

### `ProxyStreamer.stream_through` semantics

```crystal
module ProxyHelpers::ProxyStreamer
  class TooLarge < Exception; end

  def self.stream_through(
    url : String,
    dst_io : IO,
    *,
    max_bytes : Int64? = nil,
    chunk : Int32 = 64 * 1024,
    connect_timeout : Time::Span = 5.seconds,
    read_timeout : Time::Span = 15.seconds,
    on_headers : (HTTP::Client::Response ->)? = nil,
  ) : Nil
end
```

Behaviour:

- Open `HTTP::Client.get(uri) do |resp| ... end` (block form — no buffering).
- Reject non-2xx with `HTTP::Server::ClientError` (caller maps to 502).
- If `max_bytes` set: reject early if `resp.headers["Content-Length"]?` parses
  to > max; otherwise read in `chunk`-sized slices, counting bytes, and raise
  `TooLarge` the moment the running total exceeds max.
- Call `on_headers.call(resp)` once before the first chunk so the caller can
  set its own `Content-Type` / `Cache-Control` and `env.response.flush`.
- Loop: `read_bytes = resp.body_io.read(buf); break if zero; dst_io.write(buf[0, read_bytes])`.

No redirect-following is in `stream_through`; callers that need redirects
(audio-proxy does — up to 5) handle them above the helper, then call
`stream_through` once on the final URL. img-proxy passes the URL as-is
(podcast CDN artwork URLs are direct).

### `/img-proxy` rewrite

Delete `CACHE`, `CACHE_MUTEX`, `cache_get`, `cache_set`, `CACHE_MAX`. Route
becomes:

```crystal
get "/img-proxy" do |env|
  url = env.params.query["url"]?.to_s
  halt env, status_code: 400, response: "Bad Request" if url.empty?
  halt env, status_code: 400, response: "HTTPS only" unless url.starts_with?("https://")

  begin
    ProxyHelpers::ProxyStreamer.stream_through(
      url, env.response,
      max_bytes: 5_i64 * 1024 * 1024,
      on_headers: ->(resp : HTTP::Client::Response) do
        env.response.content_type = resp.headers["Content-Type"]? || "image/jpeg"
        env.response.headers["Cache-Control"] = "public, max-age=86400, immutable"
        env.response.flush
      end,
    )
  rescue ProxyHelpers::ProxyStreamer::TooLarge
    halt env, status_code: 502, response: "Upstream too large"
  rescue ex
    Log.warn { "img-proxy error url=#{url} #{ex.class}: #{ex.message}" }
    halt env, status_code: 502, response: "Bad Gateway"
  end
end
```

Per-request RAM: 64 KB buffer + ~100 KB connection state. Steady-state RAM:
zero (no cache). No concurrency cap on img-proxy.

### `/audio_proxy` rewrite

Preserve the existing redirect loop and `env.response.close` semantics — both
are load-bearing and correct (see comment block at `episodes.cr:188-197`).
Only the streaming branch changes, wrapping in `with_slot`:

```crystal
LIMITER_AUDIO = ProxyHelpers::ProxyLimiter.new(global_cap: 64, per_host_cap: 16)

get "/episodes/:id/audio_proxy" do |env|
  user = Auth.current_user(env)
  halt env, status_code: 401, response: "Unauthorized" unless user
  episode_id = env.params.url["id"].to_i64
  episode = Episode.find(episode_id)
  halt env, status_code: 404, response: "Episode not found" unless episode

  url = episode.audio_url.sub(/^http:\/\//i, "https://")
  redirects_left = 5
  streaming_started = false

  while redirects_left > 0
    redirects_left -= 1
    uri = URI.parse(url)
    begin
      LIMITER_AUDIO.with_slot(uri.host || "") do
        HTTP::Client.get(url) do |resp|
          if resp.status_code.in?(301, 302, 303, 307, 308)
            loc = resp.headers["Location"]? || raise "no Location"
            url = loc.starts_with?("http") ? loc : "#{uri.scheme}://#{uri.host}#{loc}"
            next  # loops in outer while
          end
          env.response.status_code = 200
          env.response.content_type = "audio/mpeg"
          env.response.headers["X-Accel-Buffering"] = "no"
          env.response.headers["Cache-Control"] = "no-store"
          if cl = resp.headers["Content-Length"]?
            env.response.headers["Content-Length"] = cl
          end
          env.response.flush
          streaming_started = true
          begin
            IO.copy(resp.body_io, env.response, 128 * 1024)
          rescue IO::Error
            Log.debug { "audio_proxy client disconnected mid-stream" }
          end
          env.response.close
        end
      end
      break if streaming_started
    rescue ProxyHelpers::ProxyLimiter::CapExceeded
      next if streaming_started  # impossible — raise is before headers
      env.response.headers["Retry-After"] = "2"
      halt env, status_code: 503, response: "Busy"
    end
  end
  nil
rescue ex
  next if streaming_started
  Log.error { "audio_proxy error: #{ex.message}" }
  "Proxy error"
end
```

Note: the redirect branch in the original code used `break` inside the
`HTTP::Client.get` block to fall through to the outer `while`. With the
`with_slot` wrapper, that becomes a `next` to re-iterate the outer loop. The
`break if streaming_started` exits the outer loop once a stream completes.

Worst-case RAM under cap: 64 × (128 KB buffer + ~200 KB connection state) ≈
21 MB. Well within budget at the current 1 Gi limit and comfortably below
the original 512 Mi.

## Tests

### `spec/web/proxy_helpers_spec.cr` — helper unit tests

Stand up a controllable local `HTTP::Server` fixture (binds to `127.0.0.1:0`,
randomised port) with configurable handlers:

| Test | Asserts |
|---|---|
| `stream_through copies a small body verbatim` | Output bytes equal input bytes; `on_headers` invoked exactly once before any body byte. |
| `stream_through aborts at max_bytes mid-stream` | Raises `TooLarge` after writing ≤ max_bytes; does not buffer the rest. |
| `stream_through rejects oversize Content-Length up front` | Raises `TooLarge` before reading the body when declared length exceeds max. |
| `stream_through does not buffer body` | Proxying a 10 MB body keeps `GC.stats.heap_size` delta under 1 MB (snapshot before / snapshot after). |
| `ProxyLimiter admits up to global_cap, refuses cap+1` | First N acquires succeed; N+1th raises `CapExceeded`. |
| `ProxyLimiter per-host cap isolates hosts` | 17 concurrent on host-A: 16 succeed, 17th raises. host-B can still admit 16 independently. |
| `ProxyLimiter releases slot on exception in block` | After block raises, a fresh acquire on the same host succeeds. |
| `ProxyLimiter releases both slots in order` | Mock counter check: per-host released before global. |

### `spec/web/routes/img_proxy_spec.cr` — route-level

| Test | Asserts |
|---|---|
| GET `/img-proxy?url=https://fixture/ok.jpg` | 200, `Content-Type: image/jpeg`, `Cache-Control: public, max-age=86400, immutable`, body equals fixture body. |
| GET `/img-proxy?url=https://fixture/big.jpg` (10 MB) | 502, "Upstream too large". |
| GET `/img-proxy?url=http://fixture/ok.jpg` | 400, "HTTPS only". |
| GET `/img-proxy` (no url) | 400, "Bad Request". |

### `spec/web/routes/audio_proxy_spec.cr` — route-level

| Test | Asserts |
|---|---|
| 65th concurrent request to same host | 503 with `Retry-After: 2`. Other 64 succeed. |
| Mid-stream upstream disconnect | Client sees truncated body, server logs `client disconnected mid-stream` at debug level — does not raise out. |
| 3xx → final URL | Redirect followed, slot held only for the final GET (verified by inspecting in-flight counter at peak — should equal 1 during the final fetch, not 2 across redirect + fetch). |

The last test is the one place the implementation can subtly hold two slots
at once; the spec exists to lock down the contract.

## Verification — definitions of success

1. All new specs pass; existing `spec/` suite green (`crystal spec`).
2. Manual smoke in the Mini App: artwork renders on inbox/episode/feeds/player
   screens; "save offline" on 5 episodes from the same CDN simultaneously all
   download to completion (verified by the `buzz-audio-v1` SW cache populating).
3. `kubectl top pod -n buzz-bot` 24-h observation: RSS plateau stays well below
   512 Mi under normal traffic. This is the gate that justifies a follow-up to
   revert the 1Gi memory bump.

## Risks

| Risk | Mitigation |
|---|---|
| Removing the in-memory image cache regresses image latency on the hot path | `Cache-Control: public, max-age=86400, immutable` pushes the cache to the client (browser + SW). Podcast artwork URLs are stable per-episode; the first paint pays the proxy cost, subsequent ones hit the browser cache. If we measure a meaningful latency regression, Approach C (pre-fetch at ingest) is the next step. |
| The 5 MB image ceiling clips a legitimate huge image | All sampled podcast artwork has been < 2 MB. If we discover a feed that legitimately exceeds 5 MB, raise the constant; it lives in one place. |
| ProxyLimiter slot leak on a panic path | The `ensure` block in `with_slot` releases regardless. Test "ProxyLimiter releases slot on exception in block" covers this. |
| Audio-proxy 503 → SW gives up on offline download | The SW `caches.put` flow runs on a user-initiated action; a 503 is observable on the client and can be retried. We do not need to change SW code for this fix, but the 503 → Retry-After: 2 contract makes it possible to add retry later. |
| Crystal HTTP::Client block form has a redirect-following gotcha | Audio path keeps explicit redirect loop. Img path does not follow redirects (the artwork URL stored in the DB is the canonical CDN URL). If we ever see image fetches failing because a feed serves redirects, add explicit follow there too. |

## Success criteria

- Per-request RAM bound by `chunk_size` (64 KB img / 128 KB audio) regardless
  of body size.
- Steady-state RAM contribution from `app.cr` cache: 0 bytes (cache deleted).
- audio-proxy in-flight count bound by 64 globally, 16 per host.
- Memory limit revert (`1Gi → 512Mi`) becomes a defensible follow-up, not a
  gamble.

## Implementation order

1. New `src/web/proxy_helpers.cr` with `ProxyLimiter` + `ProxyStreamer.stream_through`.
2. `spec/web/proxy_helpers_spec.cr` with the unit tests above.
3. Rewrite `src/web/routes/app.cr` `/img-proxy` to use `stream_through`; delete the cache.
4. `spec/web/routes/img_proxy_spec.cr` route tests.
5. Wrap `src/web/routes/episodes.cr` `/audio_proxy` streaming branch in `LIMITER_AUDIO.with_slot`.
6. `spec/web/routes/audio_proxy_spec.cr` route tests including the 65th-request 503 case.
7. Run full `crystal spec` suite; ensure green.
8. Single commit to `main`; deploy via `k8s/deploy.sh`; 24-h `kubectl top pod` observation.
9. (Out of scope, follow-up) Revert deployment.yaml `1Gi → 512Mi`.
