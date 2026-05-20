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
end
