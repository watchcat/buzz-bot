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
