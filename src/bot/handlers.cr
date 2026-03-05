require "tourmaline"

module Bot
  module Handlers
    def self.dispatch(update : Tourmaline::Update)
      if (message = update.message)
        handle_message(message)
      elsif (callback = update.callback_query)
        handle_callback(callback)
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

      case text.split(" ").first
      when "/start"
        handle_start(message, user)
      when "/help"
        handle_help(message)
      end
    end

    private def self.handle_start(message : Tourmaline::Message, user : User)
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

    private def self.handle_help(message : Tourmaline::Message)
      BotClient.client.send_message(
        message.chat.id,
        <<-TEXT,
          **Buzz-Bot Help**

          Commands:
          /start — Open the podcast app
          /help — Show this message

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

    private def self.handle_callback(callback : Tourmaline::CallbackQuery)
      # Acknowledge callback to remove loading state
      BotClient.client.answer_callback_query(callback.id)
    end
  end
end
