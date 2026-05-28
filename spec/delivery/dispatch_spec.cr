require "../spec_helper"
require "../../src/delivery/dispatch"

private def sub(user_id, mode, subscribed_at)
  Delivery::Dispatch::Subscriber.new(
    user_id: user_id.to_i64, telegram_id: (user_id * 10).to_i64,
    mode: mode, subscribed_at: subscribed_at
  )
end

private def ep(id, published_at, audio_url = "https://example.com/a.mp3")
  Delivery::Dispatch::EpisodeRef.new(
    id: id.to_i64, published_at: published_at, audio_url: audio_url
  )
end

private def t(s) Time.parse_utc(s, "%Y-%m-%dT%H:%M:%S") end

describe Delivery::Dispatch do
  describe ".eligible_targets" do
    it "yields one target per (subscriber, episode) pair with mode notify or mp3" do
      subs = [sub(1, "notify", t("2026-01-01T00:00:00"))]
      eps  = [ep(100, t("2026-02-01T00:00:00")), ep(101, t("2026-02-02T00:00:00"))]

      result = Delivery::Dispatch.eligible_targets(subs, eps)

      result.size.should eq 2
      result.map(&.subscriber.user_id).should eq [1_i64, 1_i64]
      result.map(&.episode.id).should eq [100_i64, 101_i64]
    end

    it "skips subscribers in 'off' mode" do
      subs = [sub(1, "off", t("2026-01-01T00:00:00"))]
      eps  = [ep(100, t("2026-02-01T00:00:00"))]

      Delivery::Dispatch.eligible_targets(subs, eps).should be_empty
    end

    it "skips episodes published before the user subscribed (backfill protection)" do
      subs = [sub(1, "notify", t("2026-03-01T00:00:00"))]
      eps  = [
        ep(100, t("2026-01-01T00:00:00")),  # before subscription — skip
        ep(101, t("2026-04-01T00:00:00")),  # after subscription  — keep
      ]

      result = Delivery::Dispatch.eligible_targets(subs, eps)

      result.size.should eq 1
      result[0].episode.id.should eq 101_i64
    end

    it "skips episodes with nil published_at" do
      subs = [sub(1, "notify", t("2026-01-01T00:00:00"))]
      eps  = [ep(100, nil)]

      Delivery::Dispatch.eligible_targets(subs, eps).should be_empty
    end

    it "skips episodes with empty audio_url" do
      subs = [sub(1, "mp3", t("2026-01-01T00:00:00"))]
      eps  = [ep(100, t("2026-02-01T00:00:00"), audio_url: "")]

      Delivery::Dispatch.eligible_targets(subs, eps).should be_empty
    end

    it "produces a cartesian product when there are multiple subscribers and episodes" do
      subs = [
        sub(1, "notify", t("2026-01-01T00:00:00")),
        sub(2, "mp3",    t("2026-01-15T00:00:00")),
      ]
      eps = [
        ep(100, t("2026-02-01T00:00:00")),
        ep(101, t("2026-02-02T00:00:00")),
      ]

      result = Delivery::Dispatch.eligible_targets(subs, eps)
      result.size.should eq 4
      modes = result.map(&.subscriber.mode).tally
      modes["notify"].should eq 2
      modes["mp3"].should eq 2
    end
  end
end
