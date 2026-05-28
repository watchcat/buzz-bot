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
  # fires exactly once on the final 2xx response (not on intermediate
  # redirect responses), before any body byte is written to dst_io, so
  # the caller can set its own Content-Type / Cache-Control / status and
  # flush before bytes flow.
  #
  # max_redirects (default 0) controls opt-in redirect-following. When 0,
  # any 3xx triggers the existing "raise upstream status N" path. When > 0,
  # 3xx responses extract Location and retry up to max_redirects times.
  # Buffer-then-resize fallback for oversized podcast artwork. The cheap
  # stream-through path in ProxyStreamer caps responses at 5 MB; a small
  # number of legitimate feeds (e.g. Lex Fridman ships a 7.8 MB 3000×3000
  # PNG) exceed that. Rather than raise the streaming cap (which would let
  # bogus HTML error pages slip through too), we route oversized fetches
  # through libvips: buffer up to RESIZE_MAX_BYTES, hand it to vipsthumbnail
  # for a max-edge resize + JPEG re-encode, and emit the small re-encoded
  # bytes as the response body. The runtime alpine image installs vips-tools
  # for the `vipsthumbnail` binary; if it's missing, ResizeFailed surfaces
  # to the route handler as a 502.
  module ImageResizer
    RESIZE_MAX_BYTES = 20_i64 * 1024 * 1024
    THUMB_SIZE       =                  600
    THUMB_QUALITY    =                   85

    class TooLarge < Exception; end

    class ResizeFailed < Exception; end

    def self.resize_through(
      url : String,
      dst_io : IO,
      *,
      max_bytes : Int64 = RESIZE_MAX_BYTES,
      size : Int32 = THUMB_SIZE,
      quality : Int32 = THUMB_QUALITY,
      connect_timeout : Time::Span = 5.seconds,
      read_timeout : Time::Span = 15.seconds,
      on_headers : (-> Nil)? = nil,
      max_redirects : Int32 = 5,
    ) : Nil
      buf = IO::Memory.new
      begin
        ProxyStreamer.stream_through(
          url, buf,
          max_bytes: max_bytes,
          connect_timeout: connect_timeout,
          read_timeout: read_timeout,
          max_redirects: max_redirects,
        )
      rescue ex : ProxyStreamer::TooLarge
        raise TooLarge.new(ex.message)
      end

      # vipsthumbnail needs file paths — stdin support varies across libvips
      # builds and the temp-file overhead is negligible next to decode work.
      input = File.tempfile("imgproxy-in")
      output_path = "#{input.path}.out.jpg"
      begin
        input.write(buf.to_slice)
        input.close

        status = Process.run(
          "vipsthumbnail",
          args: [
            input.path,
            "--size", size.to_s,
            "-o", "#{output_path}[Q=#{quality}]",
          ],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close,
        )
        unless status.success?
          raise ResizeFailed.new("vipsthumbnail exited #{status.exit_code} for #{url}")
        end

        on_headers.try &.call
        File.open(output_path, "rb") { |f| IO.copy(f, dst_io) }
      ensure
        input.delete rescue nil
        File.delete(output_path) rescue nil
      end
    end
  end

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
      max_redirects : Int32 = 0,
    ) : Nil
      current_url = url
      redirects_remaining = max_redirects

      loop do
        uri = URI.parse(current_url)
        client = HTTP::Client.new(uri)
        client.connect_timeout = connect_timeout
        client.read_timeout = read_timeout

        redirect_target = nil

        begin
          client.get(uri.request_target) do |resp|
            # Handle redirects when opt-in
            if {301, 302, 303, 307, 308}.includes?(resp.status_code)
              if redirects_remaining > 0
                loc = resp.headers["Location"]?
                raise Exception.new("redirect without Location") unless loc
                # Resolve relative Location against current URI
                redirect_target = loc.starts_with?("http") ? loc : "#{uri.scheme}://#{uri.host}#{loc}"
                # on_headers must NOT fire on intermediate redirect responses
              else
                raise "upstream status #{resp.status_code}"
              end
            elsif resp.status_code < 200 || resp.status_code >= 300
              raise "upstream status #{resp.status_code}"
            else
              # 2xx — stream the body

              # Up-front check: if the upstream declares a Content-Length that
              # parses to > max, abort before any byte is read. Malformed or
              # missing Content-Length silently falls through to the mid-stream
              # byte-counter check below — that's the safety net.
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
          end
        ensure
          client.close
        end

        if (target = redirect_target)
          redirects_remaining -= 1
          current_url = target
        else
          break
        end
      end
    end
  end
end
