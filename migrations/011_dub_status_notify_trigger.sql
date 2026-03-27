-- Trigger: fire pg_notify('dub_status', 'episode_id:lang:step:status')
-- on every UPDATE to dubbed_episodes so the SSE hub can forward it to browsers.

CREATE OR REPLACE FUNCTION notify_dub_update() RETURNS TRIGGER AS $$
BEGIN
  PERFORM pg_notify(
    'dub_status',
    NEW.episode_id::text || ':' || NEW.language || ':' || NEW.step || ':' || NEW.status
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS dub_update_notify ON dubbed_episodes;

CREATE TRIGGER dub_update_notify
AFTER UPDATE ON dubbed_episodes
FOR EACH ROW
EXECUTE FUNCTION notify_dub_update();
