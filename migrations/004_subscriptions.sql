ALTER TABLE users
  ADD COLUMN sub_type       TEXT,
  ADD COLUMN sub_expires_at TIMESTAMPTZ;
