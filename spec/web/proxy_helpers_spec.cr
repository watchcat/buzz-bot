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

      # Crystal's scheduler is cooperative; Fiber.yield hands control to the
      # next ready fiber. Each spawned fiber is runnable (blocked on
      # hold.receive only AFTER it has acquired a slot), so this loop
      # terminates in at most N yields. Same reasoning applies to the other
      # `while limiter.in_flight < N` loops in this file.
      while limiter.in_flight < 4
        Fiber.yield
      end
      limiter.in_flight.should eq(4)

      # Release them
      4.times { hold.send(nil) }
      4.times { done.receive }
      limiter.in_flight.should eq(0)
    end

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
  end

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

  describe "release" do
    it "releases the slot when the block raises" do
      limiter = ProxyHelpers::ProxyLimiter.new(global_cap: 1, per_host_cap: 1)

      expect_raises(Exception, "boom") do
        limiter.with_slot("h") { raise "boom" }
      end
      limiter.in_flight.should eq(0)

      # Slot is reusable after the raise
      ran = false
      limiter.with_slot("h") { ran = true }
      ran.should be_true
    end
  end
end

require "http/server"

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

    it "raises Exception with /upstream status/ when upstream returns non-2xx" do
      fake = FakeUpstream.new do |ctx|
        ctx.response.status_code = 404
        ctx.response.print "not found"
      end

      sink = IO::Memory.new
      header_calls = 0
      expect_raises(Exception, /upstream status 404/) do
        ProxyHelpers::ProxyStreamer.stream_through(
          fake.url("/x"), sink,
          on_headers: ->(_resp : HTTP::Client::Response) { header_calls += 1 },
        )
      end
      # No body written; on_headers never called (rejected before headers fired)
      sink.size.should eq(0)
      header_calls.should eq(0)
    ensure
      fake.try &.close
    end
  end
end
