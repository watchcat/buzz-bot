# Proxy stream-through OOM fix — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the unbounded memory growth in `/img-proxy` and `/audio_proxy` by streaming bodies through, dropping the in-memory image cache, and bounding audio-proxy concurrency.

**Architecture:** Add a shared `ProxyHelpers` module (`ProxyLimiter` + `ProxyStreamer.stream_through`) and wire it into the two route handlers. img-proxy gets stream-through + 5 MB per-response ceiling and no cache; audio-proxy gets a 64-global / 16-per-host concurrency cap with 503 over cap.

**Tech Stack:** Crystal stdlib (`HTTP::Client` block form, `Mutex`, `IO::Memory`, `HTTP::Server` for the test fixture), Kemal route DSL, `crystal spec` (stdlib).

---

## File structure

| Action | File | Responsibility |
|---|---|---|
| Create | `src/web/proxy_helpers.cr` | `ProxyHelpers::ProxyLimiter` (counter + mutex semaphore) and `ProxyHelpers::ProxyStreamer.stream_through` (chunked HTTP::Client block-form copy with `max_bytes` ceiling). |
| Create | `spec/spec_helper.cr` | `require "spec"` and source-file requires for the modules under test. |
| Create | `spec/web/proxy_helpers_spec.cr` | Unit tests: limiter caps + isolation + release-on-raise; streamer chunked-write + TooLarge mid-stream + TooLarge up-front + correct body bytes. |
| Modify | `src/buzz_bot.cr` | Add `require "./web/proxy_helpers"` so the binary links the new module. |
| Modify | `src/web/routes/app.cr` | Delete cache (`CACHE`, `CACHE_MUTEX`, `cache_get`, `cache_set`, `CACHE_MAX`); rewrite `/img-proxy` to use `ProxyStreamer.stream_through` with 5 MB ceiling and `Cache-Control: public, max-age=86400, immutable`. |
| Modify | `src/web/routes/episodes.cr` | Add `LIMITER_AUDIO = ProxyHelpers::ProxyLimiter.new(global_cap: 64, per_host_cap: 16)`; wrap the streaming branch of `/episodes/:id/audio_proxy` in `LIMITER_AUDIO.with_slot(uri.host || "") { ... }`; map `CapExceeded` to 503 with `Retry-After: 2`. |

Route-level Kemal-integration tests are **deliberately substituted with a curl-based smoke task (Task 5)** — the project has no existing Kemal route-test harness, and the helper unit tests cover the only place real concurrency logic lives. Standing up a Kemal in-process test harness would be a separate ~half-day spike out of scope of this fix.

---

## Task 1: Spec harness + ProxyLimiter (TDD)

**Files:**
- Create: `spec/spec_helper.cr`
- Create: `src/web/proxy_helpers.cr`
- Create: `spec/web/proxy_helpers_spec.cr`

- [ ] **Step 1: Create the spec harness file**

Write `spec/spec_helper.cr` with this exact content:

```crystal
require "spec"
require "../src/web/proxy_helpers"
```

- [ ] **Step 2: Create the empty module file so the spec_helper require resolves**

Write `src/web/proxy_helpers.cr` with this exact content (intentionally minimal — we'll add the class via TDD):

```crystal
require "http/client"
require "mutex"

module ProxyHelpers
end
```

- [ ] **Step 3: Write the first failing test — limiter admits up to global_cap**

Write `spec/web/proxy_helpers_spec.cr` with this exact content:

```crystal
require "../spec_helper"

describe ProxyHelpers::ProxyLimiter do
  describe "global cap" do
    it "admits up to global_cap concurrent acquisitions" do
      limiter = ProxyHelpers::ProxyLimiter.new(global_cap: 4, per_host_cap: 4)
      hold = Channel(Nil).new
      done = Channel(Nil).new

      4.times do
        spawn do
          limiter.with_slot("h") do
            hold.receive
          end
          done.send(nil)
        end
      end

      # Wait for all four fibers to take their slot
      while limiter.in_flight < 4
        Fiber.yield
      end
      limiter.in_flight.should eq(4)

      # Release them
      4.times { hold.send(nil) }
      4.times { done.receive }
      limiter.in_flight.should eq(0)
    end
  end
end
```

- [ ] **Step 4: Run the spec to verify it fails (class undefined)**

Run: `crystal spec spec/web/proxy_helpers_spec.cr`
Expected: FAIL with `undefined constant ProxyHelpers::ProxyLimiter`.

- [ ] **Step 5: Implement ProxyLimiter to satisfy the first test**

Replace the contents of `src/web/proxy_helpers.cr` with:

```crystal
require "http/client"
require "mutex"

module ProxyHelpers
  # Channel-free semaphore: global cap + per-host sub-cap. Acquisition is
  # non-blocking — if a slot is unavailable it raises CapExceeded immediately
  # (caller maps that to a 503 with Retry-After). Implemented as counter +
  # mutex for clarity; the alternative (nested Channel#send_select) is harder
  # to read and offers nothing for our use case where the caller wants the
  # back-pressure signal NOW, not whenever a slot frees up.
  class ProxyLimiter
    class CapExceeded < Exception; end

    def initialize(@global_cap : Int32, @per_host_cap : Int32)
      @global_count = 0
      @per_host_count = {} of String => Int32
      @mutex = Mutex.new
    end

    def with_slot(host : String, & : -> T) : T forall T
      acquire(host)
      begin
        yield
      ensure
        release(host)
      end
    end

    def in_flight : Int32
      @mutex.synchronize { @global_count }
    end

    private def acquire(host : String)
      @mutex.synchronize do
        if @global_count >= @global_cap
          raise CapExceeded.new("global cap #{@global_cap} reached")
        end
        host_count = @per_host_count[host]? || 0
        if host_count >= @per_host_cap
          raise CapExceeded.new("per-host cap #{@per_host_cap} reached for #{host}")
        end
        @global_count += 1
        @per_host_count[host] = host_count + 1
      end
    end

    private def release(host : String)
      @mutex.synchronize do
        @global_count -= 1
        new_count = (@per_host_count[host]? || 0) - 1
        if new_count <= 0
          @per_host_count.delete(host)
        else
          @per_host_count[host] = new_count
        end
      end
    end
  end
end
```

- [ ] **Step 6: Run the spec to verify it passes**

Run: `crystal spec spec/web/proxy_helpers_spec.cr`
Expected: PASS, 1 example, 0 failures.

- [ ] **Step 7: Add the failing test for "refuses cap+1"**

Append inside the `describe ProxyHelpers::ProxyLimiter do` block (still under the `describe "global cap"` group), before the closing `end`:

```crystal
    it "raises CapExceeded on the (global_cap + 1)th acquisition" do
      limiter = ProxyHelpers::ProxyLimiter.new(global_cap: 2, per_host_cap: 2)
      hold = Channel(Nil).new

      2.times do
        spawn do
          limiter.with_slot("h") { hold.receive }
        end
      end
      while limiter.in_flight < 2
        Fiber.yield
      end

      expect_raises(ProxyHelpers::ProxyLimiter::CapExceeded, /global cap/) do
        limiter.with_slot("h") { }
      end

      2.times { hold.send(nil) }
    end
```

- [ ] **Step 8: Run the spec to verify it passes**

Run: `crystal spec spec/web/proxy_helpers_spec.cr`
Expected: PASS, 2 examples, 0 failures.

- [ ] **Step 9: Add the failing test for per-host isolation**

Append a new describe group inside the outer `describe ProxyHelpers::ProxyLimiter do`:

```crystal
  describe "per-host cap" do
    it "isolates hosts — capped host raises while other host admits" do
      limiter = ProxyHelpers::ProxyLimiter.new(global_cap: 100, per_host_cap: 3)
      hold = Channel(Nil).new

      # Fill host-a
      3.times do
        spawn do
          limiter.with_slot("host-a") { hold.receive }
        end
      end
      while limiter.in_flight < 3
        Fiber.yield
      end

      expect_raises(ProxyHelpers::ProxyLimiter::CapExceeded, /per-host cap/) do
        limiter.with_slot("host-a") { }
      end

      # host-b is unaffected
      ran = false
      limiter.with_slot("host-b") { ran = true }
      ran.should be_true

      3.times { hold.send(nil) }
    end
  end
```

- [ ] **Step 10: Run the spec to verify it passes**

Run: `crystal spec spec/web/proxy_helpers_spec.cr`
Expected: PASS, 3 examples, 0 failures.

- [ ] **Step 11: Add the failing test for release-on-exception**

Append a new describe group inside the outer `describe`:

```crystal
  describe "release" do
    it "releases the slot when the block raises" do
      limiter = ProxyHelpers::ProxyLimiter.new(global_cap: 1, per_host_cap: 1)

      expect_raises(RuntimeError, "boom") do
        limiter.with_slot("h") { raise "boom" }
      end
      limiter.in_flight.should eq(0)

      # Slot is reusable after the raise
      ran = false
      limiter.with_slot("h") { ran = true }
      ran.should be_true
    end
  end
```

- [ ] **Step 12: Run the spec to verify it passes**

Run: `crystal spec spec/web/proxy_helpers_spec.cr`
Expected: PASS, 4 examples, 0 failures.

- [ ] **Step 13: Commit**

```bash
git add src/web/proxy_helpers.cr spec/spec_helper.cr spec/web/proxy_helpers_spec.cr
git commit -m "feat: ProxyHelpers::ProxyLimiter — global + per-host concurrency cap

Counter+mutex semaphore. Non-blocking acquire: raises CapExceeded
immediately when out of slots so the caller can return 503 with
Retry-After rather than queue. Releases on block exit (including
exceptions). Stands up the project's first Crystal spec harness.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: ProxyStreamer.stream_through (TDD)

**Files:**
- Modify: `src/web/proxy_helpers.cr`
- Modify: `spec/web/proxy_helpers_spec.cr`

- [ ] **Step 1: Write the failing test for the happy path (small body verbatim)**

Append to `spec/web/proxy_helpers_spec.cr` after the closing `end` of the `describe ProxyHelpers::ProxyLimiter do` block:

```crystal
require "http/server"

# Local HTTP fixture that lets each test install a handler closure.
class FakeUpstream
  getter port : Int32

  def initialize(&handler : HTTP::Server::Context ->)
    @server = HTTP::Server.new { |ctx| handler.call(ctx) }
    addr = @server.bind_tcp("127.0.0.1", 0)
    @port = addr.port
    spawn { @server.listen }
  end

  def url(path : String) : String
    "http://127.0.0.1:#{@port}#{path}"
  end

  def close
    @server.close
  end
end

describe ProxyHelpers::ProxyStreamer do
  describe ".stream_through" do
    it "copies a small body verbatim and calls on_headers once before any body byte" do
      body = "hello world".to_slice
      header_calls = 0
      fake = FakeUpstream.new do |ctx|
        ctx.response.headers["Content-Type"] = "image/jpeg"
        ctx.response.write(body)
      end

      sink = IO::Memory.new
      ProxyHelpers::ProxyStreamer.stream_through(
        fake.url("/x"), sink,
        on_headers: ->(resp : HTTP::Client::Response) do
          header_calls += 1
          resp.headers["Content-Type"]?.should eq("image/jpeg")
          sink.size.should eq(0)
        end,
      )
      sink.to_slice.should eq(body)
      header_calls.should eq(1)
    ensure
      fake.try &.close
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails (module undefined)**

Run: `crystal spec spec/web/proxy_helpers_spec.cr`
Expected: FAIL with `undefined constant ProxyHelpers::ProxyStreamer`.

- [ ] **Step 3: Implement ProxyStreamer.stream_through**

Append to `src/web/proxy_helpers.cr` BEFORE the final `end` that closes `module ProxyHelpers`:

```crystal
  # HTTP::Client block-form copy — no body buffering. Optional max_bytes
  # ceiling rejects oversize responses either up front (declared
  # Content-Length > max) or mid-stream (running total > max). on_headers
  # fires exactly once, before any body byte is written to dst_io, so the
  # caller can set its own Content-Type / Cache-Control / status and
  # flush before bytes flow.
  module ProxyStreamer
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
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = connect_timeout
      client.read_timeout = read_timeout

      begin
        client.get(uri.request_target) do |resp|
          if resp.status_code < 200 || resp.status_code >= 300
            raise "upstream status #{resp.status_code}"
          end

          if (max = max_bytes) && (cl_str = resp.headers["Content-Length"]?)
            if (cl = cl_str.to_i64?) && cl > max
              raise TooLarge.new("declared Content-Length #{cl} > #{max}")
            end
          end

          on_headers.try &.call(resp)

          buf = Bytes.new(chunk)
          total = 0_i64
          loop do
            n = resp.body_io.read(buf)
            break if n == 0
            total += n
            if (max = max_bytes) && total > max
              raise TooLarge.new("streamed bytes #{total} exceeded max #{max}")
            end
            dst_io.write(buf[0, n])
          end
        end
      ensure
        client.close
      end
    end
  end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run: `crystal spec spec/web/proxy_helpers_spec.cr`
Expected: PASS, 5 examples, 0 failures.

- [ ] **Step 5: Add a `CountingWriter` helper class (top of file)**

ABOVE the existing `class FakeUpstream` definition in `spec/web/proxy_helpers_spec.cr`, add this helper class (it counts the size of each `write` call, so the test can assert chunked delivery vs single-shot buffering):

```crystal
class CountingWriter < IO
  def initialize(@inner : IO, @sizes : Array(Int32))
  end

  def read(slice : Bytes) : Int32
    raise "read not supported"
  end

  def write(slice : Bytes) : Nil
    @sizes << slice.size
    @inner.write(slice)
  end
end
```

- [ ] **Step 6: Add the failing test for chunked streaming (not buffering)**

Append inside `describe ".stream_through" do`, before its closing `end`:

```crystal
    it "writes the body in multiple chunks rather than buffering all at once" do
      # 200 KB body at 64 KB chunk size — expect at least 3 separate writes
      # to the destination IO. A buffering implementation would issue 1.
      body = Bytes.new(200 * 1024) { |i| (i & 0xff).to_u8 }
      fake = FakeUpstream.new do |ctx|
        ctx.response.headers["Content-Type"] = "image/jpeg"
        ctx.response.write(body)
      end

      writes = [] of Int32
      sink = IO::Memory.new
      counting = CountingWriter.new(sink, writes)
      ProxyHelpers::ProxyStreamer.stream_through(
        fake.url("/x"), counting,
        chunk: 64 * 1024,
      )
      sink.size.should eq(body.size)
      writes.size.should be >= 3
    ensure
      fake.try &.close
    end
```

- [ ] **Step 7: Run the spec to verify it passes**

Run: `crystal spec spec/web/proxy_helpers_spec.cr`
Expected: PASS, 6 examples, 0 failures.

- [ ] **Step 8: Add the failing test for TooLarge up-front (declared Content-Length)**

Append inside `describe ".stream_through" do`, before its closing `end`:

```crystal
    it "raises TooLarge up front when declared Content-Length exceeds max_bytes" do
      body = Bytes.new(200 * 1024) { 0_u8 }
      fake = FakeUpstream.new do |ctx|
        ctx.response.headers["Content-Type"] = "image/jpeg"
        ctx.response.headers["Content-Length"] = body.size.to_s
        ctx.response.write(body)
      end

      sink = IO::Memory.new
      header_calls = 0
      expect_raises(ProxyHelpers::ProxyStreamer::TooLarge, /Content-Length/) do
        ProxyHelpers::ProxyStreamer.stream_through(
          fake.url("/x"), sink,
          max_bytes: 100_i64 * 1024,
          on_headers: ->(_resp : HTTP::Client::Response) { header_calls += 1 },
        )
      end
      # No body written; on_headers never called (we rejected before headers fired)
      sink.size.should eq(0)
      header_calls.should eq(0)
    ensure
      fake.try &.close
    end
```

- [ ] **Step 9: Run the spec to verify it passes**

Run: `crystal spec spec/web/proxy_helpers_spec.cr`
Expected: PASS, 7 examples, 0 failures.

- [ ] **Step 10: Add the failing test for TooLarge mid-stream (no Content-Length declared)**

Append inside `describe ".stream_through" do`, before its closing `end`:

```crystal
    it "raises TooLarge mid-stream when running byte total exceeds max_bytes" do
      # Send chunked encoding (no Content-Length) so the up-front check is skipped
      body = Bytes.new(200 * 1024) { 0_u8 }
      fake = FakeUpstream.new do |ctx|
        ctx.response.headers["Content-Type"] = "image/jpeg"
        # Don't set Content-Length — Crystal's HTTP::Server will chunk
        ctx.response.write(body)
      end

      sink = IO::Memory.new
      expect_raises(ProxyHelpers::ProxyStreamer::TooLarge, /streamed bytes/) do
        ProxyHelpers::ProxyStreamer.stream_through(
          fake.url("/x"), sink,
          max_bytes: 100_i64 * 1024,
          chunk: 64 * 1024,
        )
      end
      # Some bytes made it before the abort
      sink.size.should be > 0
      sink.size.should be <= 200 * 1024
    ensure
      fake.try &.close
    end
```

- [ ] **Step 11: Run the spec to verify it passes**

Run: `crystal spec spec/web/proxy_helpers_spec.cr`
Expected: PASS, 8 examples, 0 failures.

- [ ] **Step 12: Commit**

```bash
git add src/web/proxy_helpers.cr spec/web/proxy_helpers_spec.cr
git commit -m "feat: ProxyHelpers::ProxyStreamer.stream_through — chunked HTTP copy

HTTP::Client block form (no body buffering) + chunked IO.copy + optional
max_bytes ceiling. on_headers fires once before any body byte so the
caller can set Content-Type / Cache-Control and flush. Rejects oversize
up front via Content-Length and mid-stream via running byte total.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: Wire helper require + rewrite /img-proxy

**Files:**
- Modify: `src/buzz_bot.cr` (add require)
- Modify: `src/web/routes/app.cr` (delete cache, rewrite handler)

- [ ] **Step 1: Add the require so the binary links the helper**

Open `src/buzz_bot.cr`. Find this line (around line 25):

```crystal
require "./web/sanitizer"
```

Add a new line immediately after it:

```crystal
require "./web/proxy_helpers"
```

The result should look like:

```crystal
require "./web/assets"
require "./web/sanitizer"
require "./web/proxy_helpers"
require "./web/server"
require "./web/json_helpers"
```

- [ ] **Step 2: Replace the entire contents of `src/web/routes/app.cr`**

Write the file with exactly this content:

```crystal
require "ecr"
require "http/client"

module Web::Routes::App
  # 5 MB ceiling on /img-proxy responses. Defends against HTML error pages
  # mis-served as images and accidental huge artwork. All sampled podcast
  # artwork in the corpus is < 2 MB; raise if a legitimate feed exceeds.
  IMG_PROXY_MAX_BYTES = 5_i64 * 1024 * 1024

  def self.register
    get "/app" do |env|
      env.response.content_type = "text/html"
      env.response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
      ECR.render "src/views/layout.ecr"
    end

    get "/" do |env|
      env.response.redirect "/app"
    end

    # Image proxy — serves external podcast artwork through our own origin to
    # satisfy Telegram WebApp's restrictive img-src CSP. Streams the body
    # through via HTTP::Client block form (no buffering); aborts with 502 if
    # the upstream declares (or streams) more than IMG_PROXY_MAX_BYTES. No
    # in-process cache — we rely on Cache-Control for browser + SW shell.
    get "/img-proxy" do |env|
      url = env.params.query["url"]?.to_s
      halt env, status_code: 400, response: "Bad Request" if url.empty?
      halt env, status_code: 400, response: "HTTPS only" unless url.starts_with?("https://")

      headers_sent = false
      begin
        ProxyHelpers::ProxyStreamer.stream_through(
          url, env.response,
          max_bytes: IMG_PROXY_MAX_BYTES,
          on_headers: ->(resp : HTTP::Client::Response) do
            env.response.content_type = resp.headers["Content-Type"]? || "image/jpeg"
            env.response.headers["Cache-Control"] = "public, max-age=86400, immutable"
            env.response.flush
            headers_sent = true
          end,
        )
      rescue ex : ProxyHelpers::ProxyStreamer::TooLarge
        if headers_sent
          Log.warn { "img-proxy mid-stream TooLarge url=#{url}: #{ex.message}" }
          env.response.close
        else
          halt env, status_code: 502, response: "Upstream too large"
        end
      rescue ex
        if headers_sent
          Log.warn { "img-proxy mid-stream error url=#{url} #{ex.class}: #{ex.message}" }
          env.response.close
        else
          Log.warn { "img-proxy error url=#{url} #{ex.class}: #{ex.message}" }
          halt env, status_code: 502, response: "Bad Gateway"
        end
      end
    end
  end
end
```

- [ ] **Step 3: Verify the binary still compiles**

Run: `nix-shell --packages crystal --run "crystal build src/buzz_bot.cr --no-codegen"`
Expected: no output, exit 0. (`--no-codegen` runs the typechecker without emitting an object file — faster than a full build, sufficient to catch the kinds of errors a deletion + rewrite could introduce.)

- [ ] **Step 4: Run the full Crystal spec suite — still green**

Run: `crystal spec`
Expected: 8 examples, 0 failures (the existing helper specs).

- [ ] **Step 5: Commit**

```bash
git add src/buzz_bot.cr src/web/routes/app.cr
git commit -m "fix(img-proxy): stream-through, drop unbounded cache, 5 MB ceiling

Was: HTTP::Client.get(url) buffered the entire body, .to_slice.dup
doubled it transiently, and a 500-entry FIFO cache stored {Bytes, String}
with no byte cap — worst case ~1.5 GB on a 1-3 MB-artwork corpus.

Now: ProxyHelpers::ProxyStreamer.stream_through copies in 64 KB chunks
via HTTP::Client block form. No cache; Cache-Control: public,
max-age=86400, immutable pushes caching to browser + SW shell. Aborts
with 502 if upstream declares or streams more than 5 MB.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Wrap /audio_proxy in LIMITER_AUDIO

**Files:**
- Modify: `src/web/routes/episodes.cr` — add module-scope `LIMITER_AUDIO` constant just below the `module Web::Routes::Episodes` line (Step 1); replace the `/episodes/:id/audio_proxy` handler block at lines 188–248 (Step 2).

- [ ] **Step 1: Add the module-scope `LIMITER_AUDIO` constant**

In `src/web/routes/episodes.cr`, find the existing `module Web::Routes::Episodes` line (line 4). Immediately after it (before `def self.register`), insert:

```crystal
  # Global semaphore: bound concurrent in-flight audio_proxy fibers so a
  # stalled upstream CDN can't accumulate fibers without limit. Caps:
  # 64 globally (~21 MB worst-case RAM at 128 KB chunk + ~200 KB conn
  # state per fiber); 16 per upstream host so one bad CDN can't monopolise
  # the pool. Note: audio_proxy is ONLY used for the service worker's
  # background "save for offline" flow — actual listening streams direct
  # from the CDN and never traverses our pod. Crystal requires constants at
  # module/class body scope (not inside method bodies).
  LIMITER_AUDIO = ProxyHelpers::ProxyLimiter.new(global_cap: 64, per_host_cap: 16)

```

The result should look like:

```crystal
module Web::Routes::Episodes
  # Global semaphore: ... (comment as above)
  LIMITER_AUDIO = ProxyHelpers::ProxyLimiter.new(global_cap: 64, per_host_cap: 16)

  def self.register
    # Fetch minimal metadata for a set of episode IDs ...
```

- [ ] **Step 2: Replace the entire `/episodes/:id/audio_proxy` handler block**

In `src/web/routes/episodes.cr`, find the section starting with the comment `# Stream episode audio via server-side proxy` (around line 188 — now shifted ~10 lines down by Step 1's insertion) and ending with the `end` after `Log.error { "audio_proxy error: ... }` (around line 248). Replace those lines with this exact content:

```crystal
    # Stream episode audio via server-side proxy (follows redirects, auth-gated).
    # Only used for background download (the audio element plays from the direct
    # CDN URL). After IO.copy we call env.response.close so that:
    #   - chunked responses get the "0\r\n\r\n" terminator before Kemal's
    #     post-processing runs (without this, Kemal raising "Headers already sent"
    #     would close the socket without the terminator, the browser sees an
    #     incomplete response and discards the download)
    #   - Content-Length responses are cleanly finalised
    # The rescue only fires for errors that occur BEFORE headers are sent; once
    # streaming has started we let the connection close naturally.
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
                loc = resp.headers["Location"]? || break
                url = loc.starts_with?("http") ? loc : "#{uri.scheme}://#{uri.host}#{loc}"
              else
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
          end
          break if streaming_started
        rescue ProxyHelpers::ProxyLimiter::CapExceeded => ex
          # CapExceeded fires before any header is written, so the response
          # is still mutable.
          Log.info { "audio_proxy 503 — #{ex.message}" }
          env.response.headers["Retry-After"] = "2"
          halt env, status_code: 503, response: "Busy"
        end
      end
      nil
    rescue ex
      # Only log/respond if streaming hadn't started yet; once we've flushed
      # headers and begun sending bytes, any exception is a Kemal housekeeping
      # artefact — the stream was already properly closed above.
      next if streaming_started
      Log.error { "audio_proxy error: #{ex.message}" }
      "Proxy error"
    end
```

Notes on the diff:
- `LIMITER_AUDIO` constant added immediately above the route, inside `def self.register`. Constants inside method bodies in Crystal are accessible from the route's `do |env|` block via closure on the module namespace; they're initialised once at first call. Acceptable here because `register` runs exactly once at boot.
- The redirect branch retains the original `break` (inside `HTTP::Client.get do |resp|`); `break` in a Crystal block exits the yielding method, so `.get` returns and we fall out of `with_slot`, then check `break if streaming_started` (false on redirect path), then the outer `while` loops with the updated `url`.
- The success branch falls off the end of the `HTTP::Client.get` block naturally after `env.response.close`. `.get` returns, `with_slot` returns, `break if streaming_started` (true) exits the outer `while`.
- `CapExceeded` is caught around the `with_slot` call. Because acquisition raises BEFORE the block runs, we know no headers have been sent and the response is still mutable — safe to `halt` with 503 + `Retry-After: 2`.

- [ ] **Step 3: Verify the binary still compiles**

Run: `nix-shell --packages crystal --run "crystal build src/buzz_bot.cr --no-codegen"`
Expected: no output, exit 0.

- [ ] **Step 4: Run the full Crystal spec suite — still green**

Run: `crystal spec`
Expected: 8 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add src/web/routes/episodes.cr
git commit -m "fix(audio_proxy): bound concurrency to 64 global / 16 per-host

Wraps the streaming branch in LIMITER_AUDIO.with_slot. CapExceeded
raises before any header is sent, so we return 503 with Retry-After: 2
when the cap is hit. Per-host sub-cap keeps a single stalled CDN from
monopolising the pool. Worst-case RAM under cap: 64 × (128 KB chunk +
conn state) ≈ 21 MB, comfortably within budget.

audio_proxy is not in the listening path — only the SW save-offline
flow proxies through here.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Local boot + curl smoke (substitutes route-level Kemal specs)

This task is **operator-run**. It verifies the integrated behaviour end-to-end against a locally booted buzz-bot, without standing up a Kemal in-process test harness.

**Files:** none modified. Local execution only.

- [ ] **Step 1: Boot buzz-bot locally**

Open a terminal and run:

```bash
cd /Users/watchcat/work/crystal/buzz-bot
nix-shell --packages crystal --run "BOT_TOKEN=fake DATABASE_URL=$(kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get secret buzz-bot-env -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#') WEBHOOK_URL=http://localhost:3000/webhook PORT=3000 crystal run src/buzz_bot.cr"
```

Expected: Kemal logs `[server] Kemal is ready to lead at http://0.0.0.0:3000`. Leave this terminal open.

- [ ] **Step 2: img-proxy happy path — real podcast artwork**

In a second terminal:

```bash
curl -sS -o /tmp/img.jpg -w "HTTP %{http_code}  size=%{size_download}  ct=%{content_type}\n" \
  "http://localhost:3000/img-proxy?url=https://is1-ssl.mzstatic.com/image/thumb/Podcasts116/v4/8a/4c/56/8a4c56e4-1c4b-2d3e-4f50-a6b7c8d9e0f1/mza_default.jpg/600x600bb.jpg"
```

(If that exact URL 404s, substitute any real `https://` image URL from an existing feed in the DB — the goal is "200 + an image".)

Expected: `HTTP 200  size=<some bytes>  ct=image/jpeg` (or whatever the upstream Content-Type is). `file /tmp/img.jpg` should report a real image format.

- [ ] **Step 3: img-proxy rejects HTTP scheme**

```bash
curl -sS -o /dev/null -w "HTTP %{http_code}\n" "http://localhost:3000/img-proxy?url=http://example.com/x.jpg"
```

Expected: `HTTP 400`.

- [ ] **Step 4: img-proxy rejects oversize upstream**

Use a known-large HTTPS asset. The Ubuntu desktop ISO is reliably > 5 MB:

```bash
curl -sS -o /dev/null -w "HTTP %{http_code}\n" \
  "http://localhost:3000/img-proxy?url=https://releases.ubuntu.com/22.04/ubuntu-22.04.4-desktop-amd64.iso"
```

Expected: `HTTP 502`. (Aborts up front on declared Content-Length > 5 MB.)

- [ ] **Step 5: audio_proxy returns 503 once cap is exceeded**

You will need a valid `X-Init-Data` header to pass `Auth.current_user`. Easiest path: open the Mini App locally in a browser, open DevTools → Network, copy the `X-Init-Data` value from any request to the Mini App. Save it to a shell variable:

```bash
INIT_DATA='paste-the-value-here'
```

Pick a known episode ID that has an audio URL on a slow-enough CDN that 65 fetches won't all complete instantly. Any podcast hosted on an HTTP-redirecting CDN works. Let `EID=<id>`:

```bash
EID=<some episode id from the db>
seq 1 70 | xargs -P 70 -I{} curl -sS -o /dev/null \
  -H "X-Init-Data: $INIT_DATA" \
  -w "%{http_code}\n" \
  "http://localhost:3000/episodes/$EID/audio_proxy" | sort | uniq -c
```

Expected: a mix of `200` (the first ≤ 64) and `503` (the rest). At least one `503` row in the `uniq -c` summary proves the cap is engaged.

- [ ] **Step 6: Stop the local boot**

In the first terminal, Ctrl-C to stop the buzz-bot process.

- [ ] **Step 7: Commit nothing**

Smoke results are recorded in the operator's terminal scrollback. No code change in this task — proceed to Task 6 once the four smoke results above pass.

---

## Task 6: Deploy to k3s + 24-h observation

This task is **operator-run**. Single PR is already committed via Tasks 1-4 to `main`; deploy ships those commits.

**Files:** none modified.

- [ ] **Step 1: Push commits to main**

```bash
cd /Users/watchcat/work/crystal/buzz-bot
git push origin main
```

Expected: `main -> main` push success.

- [ ] **Step 2: Run the deploy script**

```bash
./k8s/deploy.sh
```

Expected (final lines):

```
==> Rolling out deployment
deployment.apps/buzz-bot restarted
deployment "buzz-bot" successfully rolled out
==> Done
```

- [ ] **Step 3: Verify the new pod is healthy**

```bash
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get pods -l app=buzz-bot
```

Expected: one pod, `STATUS=Running`, `RESTARTS=0`, age < 5m.

- [ ] **Step 4: Capture starting RSS**

```bash
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot top pod -l app=buzz-bot
```

Expected: a line like `buzz-bot-<hash>   <cpu>m   <rss>Mi`. Record the `<rss>Mi` value as the post-deploy baseline (typically ~80–150 Mi).

- [ ] **Step 5: 24-h observation gate**

After 24 hours of normal traffic, re-run:

```bash
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot top pod -l app=buzz-bot
kubectl --kubeconfig k8s/kubeconfig -n buzz-bot get pods -l app=buzz-bot -o wide
```

Expected: RSS plateau well below 512 Mi (the goal is to prove we can safely revert the 1Gi bump). `RESTARTS=0`. No OOMKilled events in `kubectl describe pod`.

- [ ] **Step 6: Sanity-check the production Mini App**

Open https://app.buzz-bot.top in the Telegram WebApp. Verify:
- Inbox, episode detail, feeds, player screens render with artwork.
- A new feed subscription's artwork loads.
- Tap "save offline" on one episode — completes (the `buzz-audio-v1` SW cache populates; the offline indicator appears).

- [ ] **Step 7: File follow-up to revert the 1Gi memory bump (out of scope of this plan)**

If steps 5 and 6 both pass, the 1Gi limit is now defensibly revertable. Create a small task to revert `k8s/deployment.yaml:38 memory: 1Gi → 512Mi` and redeploy. This is intentionally separate so we get observation evidence before changing the safety net.

---

## Out-of-scope follow-ups (documented for trace)

- Revert `k8s/deployment.yaml:38 memory: 1Gi → 512Mi` — see Task 6 Step 7.
- Pre-fetch + resize podcast artwork at RSS-ingest (Approach C from the spec) — only worth doing if cold-fetch latency on `/img-proxy` becomes the next pain point.
- Kemal in-process route-test harness — would let us add the route-level specs the design originally called for; substituted here with Task 5 curl smoke.
- Range-request support on `/audio_proxy` — not needed (listening goes direct to CDN).
- Prometheus metrics for proxy in-flight counts — log lines suffice; revisit if we need historical graphs.
