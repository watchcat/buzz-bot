require "tourmaline"
require "../config"

# MiniAppLink — single source of truth for inline buttons that open the
# Mini App at a specific destination. Keeps bot-side notification code
# from duplicating the label/URL convention.
module MiniAppLink
  # Standard "open this episode in the Mini App" inline button. Used by
  # all bot-side notifications (dub-finished, new-episode delivery, ...).
  def self.episode_button(episode_id : Int64) : Tourmaline::InlineKeyboardButton
    Tourmaline::InlineKeyboardButton.new(
      text:    "▶️ Open Episode",
      web_app: Tourmaline::WebAppInfo.new(url: "#{Config.base_url}/app?episode=#{episode_id}"),
    )
  end
end
