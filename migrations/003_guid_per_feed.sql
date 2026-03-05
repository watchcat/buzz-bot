-- GUIDs must be unique per feed, not globally.
-- Two different feed URLs can carry the same podcast (e.g. FeedBurner mirrors)
-- and will produce identical GUIDs. A global UNIQUE on guid causes the second
-- feed to silently steal episodes from the first on upsert conflict.
ALTER TABLE episodes DROP CONSTRAINT episodes_guid_key;
ALTER TABLE episodes ADD CONSTRAINT episodes_feed_id_guid_key UNIQUE (feed_id, guid);
