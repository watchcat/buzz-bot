require "../spec_helper"
require "../../src/bot/mini_app_link"

describe MiniAppLink do
  describe ".episode_button" do
    it "uses the standard '▶️ Open Episode' label" do
      btn = MiniAppLink.episode_button(123_i64)
      btn.text.should eq "▶️ Open Episode"
    end

    it "targets the Mini App's episode-specific deep link" do
      btn = MiniAppLink.episode_button(456_i64)
      url = btn.web_app.try(&.url) || ""
      url.should contain("/app?episode=456")
    end

    it "uses the configured base_url so prod vs staging stays correct" do
      btn = MiniAppLink.episode_button(789_i64)
      url = btn.web_app.try(&.url) || ""
      url.should start_with(Config.base_url)
    end
  end
end
