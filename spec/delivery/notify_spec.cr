require "../spec_helper"
require "../../src/delivery/notify"

describe Delivery::Notify do
  describe ".build_caption" do
    it "includes feed title, episode title, date, and duration" do
      caption = Delivery::Notify.build_caption(
        feed_title:    "NRC Vandaag",
        episode_title: "In Ter Apel voelt iedereen zich in de…",
        published_at:  Time.utc(2026, 5, 28, 9, 0, 0),
        duration_sec:  18 * 60,
      )

      caption.should contain("*NRC Vandaag*")
      caption.should contain("new episode")
      caption.should contain("In Ter Apel voelt iedereen zich in de…")
      caption.should contain("May 28, 2026")
      caption.should contain("18 min")
    end

    it "omits duration when nil" do
      caption = Delivery::Notify.build_caption(
        feed_title:    "Daily",
        episode_title: "Untitled",
        published_at:  Time.utc(2026, 1, 2),
        duration_sec:  nil,
      )

      caption.should_not contain("min")
      caption.should contain("Jan 2, 2026")
    end

    it "omits date when published_at is nil" do
      caption = Delivery::Notify.build_caption(
        feed_title:    "Daily",
        episode_title: "Untitled",
        published_at:  nil,
        duration_sec:  300,
      )

      caption.should_not contain(",")
      caption.should contain("5 min")
    end

    it "formats hours and minutes for long episodes" do
      caption = Delivery::Notify.build_caption(
        feed_title:    "Hardcore History",
        episode_title: "Wrath of the Khans",
        published_at:  Time.utc(2026, 5, 1),
        duration_sec:  3 * 3600 + 25 * 60,
      )

      caption.should contain("3h 25m")
    end
  end
end
