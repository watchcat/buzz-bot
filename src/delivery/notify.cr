require "tourmaline"
require "../bot/client"
require "../bot/mini_app_link"
require "../config"
require "../models/feed"
require "../models/episode"

# Delivery::Notify — formats and sends the "notify" mode Telegram card.
# A card is a send_photo (when feed.image_url is present) with the episode
# title in the caption and a Mini-App-launching Listen button; falls back
# to send_message with the same text/button when no cover or when
# send_photo fails (bad URL, upstream 404, etc).
module Delivery::Notify
  MONTH_ABBR = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]

  # Pure: build the markdown caption. Extracted so it's unit-testable.
  def self.build_caption(feed_title : String, episode_title : String,
                          published_at : Time?, duration_sec : Int32?) : String
    parts = ["*#{feed_title}* · new episode", episode_title]

    meta = [] of String
    if (pub = published_at)
      meta << "#{MONTH_ABBR[pub.month - 1]} #{pub.day}, #{pub.year}"
    end
    if (sec = duration_sec) && sec > 0
      meta << fmt_duration(sec)
    end
    parts << meta.join(" · ") unless meta.empty?

    parts.join("\n")
  end

  def self.send(telegram_id : Int64, feed : Feed, episode : Episode)
    caption = build_caption(
      feed_title:    feed.title || "Podcast",
      episode_title: episode.title,
      published_at:  episode.published_at,
      duration_sec:  episode.duration_sec,
    )

    # Standard inline button — shared with dub-result notifications via
    # MiniAppLink (introduced in Task 3a).
    markup = Tourmaline::InlineKeyboardMarkup.new([[
      MiniAppLink.episode_button(episode.id),
    ]])

    if (img = feed.image_url)
      begin
        BotClient.client.send_photo(
          chat_id:      telegram_id,
          photo:        img,
          caption:      caption,
          parse_mode:   Tourmaline::ParseMode::Markdown,
          reply_markup: markup,
        )
        Log.info { "Delivery[notify ep=#{episode.id} tg=#{telegram_id}]: photo sent" }
        return
      rescue ex
        Log.warn { "Delivery[notify ep=#{episode.id} tg=#{telegram_id}]: photo send failed (#{ex.message}) — falling back to text" }
      end
    end

    BotClient.client.send_message(
      telegram_id, caption,
      parse_mode:   Tourmaline::ParseMode::Markdown,
      reply_markup: markup,
    )
    Log.info { "Delivery[notify ep=#{episode.id} tg=#{telegram_id}]: text sent" }
  rescue ex
    Log.error { "Delivery[notify ep=#{episode.id} tg=#{telegram_id}]: send failed — #{ex.message}" }
  end

  private def self.fmt_duration(sec : Int32) : String
    h = sec // 3600
    m = (sec % 3600) // 60
    h > 0 ? "#{h}h #{m}m" : "#{m} min"
  end
end
