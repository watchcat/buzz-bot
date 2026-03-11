require "tourmaline"

module Bot
  module Handlers
    def self.dispatch(update : Tourmaline::Update)
      if (message = update.message)
        if (payment = message.successful_payment)
          handle_successful_payment(message, payment)
        elsif message.text
          handle_message(message)
        end
      elsif (callback = update.callback_query)
        handle_callback(callback)
      elsif (query = update.pre_checkout_query)
        handle_pre_checkout_query(query)
      end
    rescue ex
      Log.error { "Handler error: #{ex.message}" }
    end

    private def self.handle_message(message : Tourmaline::Message)
      text = message.text || return
      user_data = message.from || return

      # Upsert user in DB
      user = User.upsert(
        user_data.id.to_i64,
        user_data.username,
        user_data.first_name,
        user_data.last_name
      )

      parts = text.split(" ", limit: 2)
      cmd   = parts.first
      param = parts[1]? || ""

      case cmd
      when "/start"     then handle_start(message, user, param)
      when "/help"      then handle_help(message)
      when "/subscribe" then send_subscribe_keyboard(message.chat.id)
      end
    end

    private def self.handle_start(message : Tourmaline::Message, user : User, param : String = "")
      if param == "subscribe"
        send_subscribe_keyboard(message.chat.id)
        return
      end

      if param.starts_with?("ep_")
        episode_id = param[3..].to_i64?
        if episode_id && (episode = Episode.find(episode_id))
          feed = Feed.find(episode.feed_id)
          podcast_name = feed.try(&.title) || "Unknown Podcast"
          app_url = "#{Config.base_url}/app?episode=#{episode_id}"
          BotClient.client.send_message(
            message.chat.id,
            "🎧 *#{escape_md(episode.title)}*\n_#{escape_md(podcast_name)}_",
            parse_mode: Tourmaline::ParseMode::MarkdownV2,
            reply_markup: Tourmaline::InlineKeyboardMarkup.new([[
              Tourmaline::InlineKeyboardButton.new(
                text: "▶️ Open Episode",
                web_app: Tourmaline::WebAppInfo.new(url: app_url)
              )
            ]])
          )
          return
        end
      end

      name = user.first_name || user.username || "there"
      app_url = "#{Config.base_url}/app"

      keyboard = Tourmaline::InlineKeyboardMarkup.new([
        [
          Tourmaline::InlineKeyboardButton.new(
            text: "🎧 Open Buzz-Bot",
            web_app: Tourmaline::WebAppInfo.new(url: app_url)
          )
        ]
      ])

      BotClient.client.send_message(
        message.chat.id,
        "Hey #{name}! 👋\n\nWelcome to **Buzz-Bot** — your personal podcast companion.\n\nSubscribe to RSS feeds, track your listening progress, and discover new episodes recommended just for you.",
        parse_mode: Tourmaline::ParseMode::Markdown,
        reply_markup: keyboard
      )
    end

    private def self.escape_md(text : String) : String
      text.gsub(/[_*\[\]()~`>#+\-=|{}.!\\]/) { |c| "\\#{c}" }
    end

    private def self.handle_help(message : Tourmaline::Message)
      BotClient.client.send_message(
        message.chat.id,
        <<-TEXT,
          **Buzz-Bot Help**

          Commands:
          /start — Open the podcast app
          /help — Show this message
          /subscribe — Get Buzz-Bot Premium

          **Features:**
          • Subscribe to any podcast RSS feed
          • Import feeds from an OPML file
          • Track listening progress across episodes
          • Like/dislike episodes to get personalized recommendations
          • Collaborative filtering: discover what similar listeners enjoy
          TEXT
        parse_mode: Tourmaline::ParseMode::Markdown
      )
    end

    private def self.send_subscribe_keyboard(chat_id : Int64)
      keyboard = Tourmaline::InlineKeyboardMarkup.new([[
        Tourmaline::InlineKeyboardButton.new(text: "📅 Monthly — 100⭐", callback_data: "sub:monthly"),
        Tourmaline::InlineKeyboardButton.new(text: "📆 Yearly — 1,000⭐", callback_data: "sub:yearly")
      ]])
      BotClient.client.send_message(chat_id,
        "⭐ *Buzz\\-Bot Premium*\n\nUnlock speed control \\(1\\.5× / 2×\\) and episode sending to Telegram\\.\n\nChoose your plan:",
        parse_mode: Tourmaline::ParseMode::MarkdownV2,
        reply_markup: keyboard
      )
    end

    private def self.handle_callback(callback : Tourmaline::CallbackQuery)
      BotClient.client.answer_callback_query(callback.id)

      case callback.data
      when "sub:monthly" then send_subscription_invoice(callback.from.id.to_i64, "monthly")
      when "sub:yearly"  then send_subscription_invoice(callback.from.id.to_i64, "yearly")
      end
    end

    private def self.send_subscription_invoice(chat_id : Int64, plan : String)
      if plan == "monthly"
        BotClient.client.send_invoice(
          chat_id,
          title:          "Buzz-Bot Premium — Monthly",
          description:    "Speed control (1.5×/2×) + send episodes to Telegram, for 30 days",
          payload:        "monthly",
          provider_token: "",
          currency:       "XTR",
          prices:         [Tourmaline::LabeledPrice.new(label: "Monthly", amount: 100)]
        )
      else
        BotClient.client.send_invoice(
          chat_id,
          title:          "Buzz-Bot Premium — Yearly",
          description:    "Speed control (1.5×/2×) + send episodes to Telegram, for one year",
          payload:        "yearly",
          provider_token: "",
          currency:       "XTR",
          prices:         [Tourmaline::LabeledPrice.new(label: "Yearly", amount: 1000)]
        )
      end
    end

    private def self.handle_pre_checkout_query(query : Tourmaline::PreCheckoutQuery)
      BotClient.client.answer_pre_checkout_query(query.id, ok: true)
    rescue ex
      Log.error { "pre_checkout_query error: #{ex.message}" }
      BotClient.client.answer_pre_checkout_query(query.id, ok: false, error_message: "Internal error")
    end

    private def self.handle_successful_payment(message : Tourmaline::Message, payment : Tourmaline::SuccessfulPayment)
      user_data = message.from || return
      user = User.find_by_telegram_id(user_data.id.to_i64) || return

      plan = payment.invoice_payload  # "monthly" or "yearly"
      expires_at = plan == "yearly" ? Time.utc + 366.days : Time.utc + 35.days

      User.update_subscription(user.id, plan, expires_at)
      BotClient.client.send_message(
        message.chat.id,
        "🎉 Thank you\\! Your Buzz\\-Bot Premium subscription is active until *#{escape_md(expires_at.to_s("%B %d, %Y"))}*\\.",
        parse_mode: Tourmaline::ParseMode::MarkdownV2
      )
    rescue ex
      Log.error { "successful_payment error: #{ex.message}" }
    end
  end
end
