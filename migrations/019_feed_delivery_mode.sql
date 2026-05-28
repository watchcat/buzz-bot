-- 019_feed_delivery_mode.sql
-- Per-feed delivery mode + last-viewed timestamp on user_feeds.
-- Joins the existing episode_order column already on the same table.

ALTER TABLE user_feeds
  ADD COLUMN delivery_mode  VARCHAR(8)  NOT NULL DEFAULT 'off',
  ADD COLUMN last_viewed_at TIMESTAMPTZ;

ALTER TABLE user_feeds
  ADD CONSTRAINT user_feeds_delivery_mode_chk
  CHECK (delivery_mode IN ('off', 'notify', 'mp3'));

-- Partial index for the fanout lookup:
--   "who wants Telegram delivery for this feed?"
-- Off-mode subscribers (the majority) are skipped by the WHERE clause.
CREATE INDEX user_feeds_by_feed_delivery
  ON user_feeds (feed_id, delivery_mode)
  WHERE delivery_mode <> 'off';
