ALTER TABLE feeds
  ADD COLUMN etag          TEXT,
  ADD COLUMN last_modified TEXT,
  ADD COLUMN ttl_minutes   INT;
