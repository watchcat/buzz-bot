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
