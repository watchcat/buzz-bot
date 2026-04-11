require "dotenv"
require "log"

# Load environment variables
Dotenv.load if File.exists?(".env")

require "./config"
require "./db"
require "./models/user"
require "./models/feed"
require "./models/episode"
require "./models/user_episode"
require "./models/dubbed_episode"
require "./models/dub_segment"
require "./dub/hub"
require "./dub/r2_storage"
require "./rss/parser"
require "./web/auth"
require "./bot/client"
require "./bot/handlers"
require "./bot/audio_sender"
require "./feed_refresher"
require "./web/assets"
require "./web/sanitizer"
require "./web/server"
require "./web/json_helpers"
require "./web/routes/webhook"
require "./web/routes/app"
require "./web/routes/feeds"
require "./web/routes/episodes"
require "./web/routes/inbox"
require "./web/routes/search"
require "./web/routes/discover"
require "./web/routes/dub"
require "./web/routes/subtitles"
require "./web/routes/flags"
require "./feature_flags"

Log.setup(:info)

Log.info { "Starting Buzz-Bot..." }

# Initialize DB connection pool
db = AppDB.pool
Log.info { "Database connected" }
FeatureFlags.setup!
DubHub.instance.start

# Register Telegram webhook
BotClient.register_webhook

# Start background feed refresh (initial scan + periodic loop)
FeedRefresher.start

# Configure and start Kemal web server
WebServer.setup

Log.info { "Server starting on port #{Config.port}" }
WebServer.run(Config.port)
