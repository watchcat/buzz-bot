require "json"
require "../db"

# UserFeed — per-user, per-feed state stored in the `user_feeds` table.
# (The Feed model owns feed-level data; user_feeds joins users ↔ feeds with
# per-relationship settings like episode_order, delivery_mode, last_viewed_at.)
struct UserFeed
  VALID_DELIVERY_MODES = %w[off notify mp3]

  # Subscriber projection used by the delivery fanout. Carries everything
  # needed to build a delivery target without re-querying.
  record Subscriber,
    user_id       : Int64,
    telegram_id   : Int64,
    mode          : String,
    subscribed_at : Time

  def self.set_delivery_mode(user_id : Int64, feed_id : Int64, mode : String) : Bool
    raise ArgumentError.new("invalid delivery mode: #{mode}") unless VALID_DELIVERY_MODES.includes?(mode)
    result = AppDB.pool.exec(
      "UPDATE user_feeds SET delivery_mode = $3 WHERE user_id = $1 AND feed_id = $2",
      user_id, feed_id, mode
    )
    result.rows_affected > 0
  end

  def self.get_delivery_mode(user_id : Int64, feed_id : Int64) : String
    AppDB.pool.query_one?(
      "SELECT delivery_mode FROM user_feeds WHERE user_id = $1 AND feed_id = $2",
      user_id, feed_id, as: String
    ) || "off"
  end

  def self.touch_viewed(user_id : Int64, feed_id : Int64) : Bool
    result = AppDB.pool.exec(
      "UPDATE user_feeds SET last_viewed_at = NOW() WHERE user_id = $1 AND feed_id = $2",
      user_id, feed_id
    )
    result.rows_affected > 0
  end

  def self.last_viewed_at(user_id : Int64, feed_id : Int64) : Time?
    AppDB.pool.query_one?(
      "SELECT last_viewed_at FROM user_feeds WHERE user_id = $1 AND feed_id = $2",
      user_id, feed_id, as: Time?
    )
  end

  # Returns every subscriber to `feed_id` whose delivery_mode is one of the
  # active modes ('notify' or 'mp3'). Used by Delivery::Dispatch.fanout.
  def self.delivery_subscribers_for(feed_id : Int64) : Array(Subscriber)
    out = [] of Subscriber
    AppDB.pool.query_each(
      <<-SQL,
        SELECT uf.user_id, u.telegram_id, uf.delivery_mode, uf.created_at
        FROM user_feeds uf
        JOIN users u ON u.id = uf.user_id
        WHERE uf.feed_id = $1 AND uf.delivery_mode <> 'off'
      SQL
      feed_id
    ) do |rs|
      out << Subscriber.new(
        user_id:       rs.read(Int64),
        telegram_id:   rs.read(Int64),
        mode:          rs.read(String),
        subscribed_at: rs.read(Time),
      )
    end
    out
  end
end
