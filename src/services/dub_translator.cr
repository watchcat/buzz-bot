require "../config"
require "../db"
require "../models/episode"
require "../models/dubbed_episode"
require "../dub/deepl_client"

Log.setup_from_env

Log.info { "DubTranslator: starting" }
DubbedEpisode.reset_in_flight("translating", "translation")

loop do
  if (job = DubbedEpisode.claim_for_translation)
    dub_id, episode_id, language = job
    process(dub_id, episode_id, language)
    sleep 100.milliseconds
  else
    sleep 5.seconds
  end
end

def process(dub_id : Int64, episode_id : Int64, language : String)
  Log.info { "DubTranslator[#{dub_id}]: claimed (episode #{episode_id} → #{language})" }

  transcript = Episode.transcript(episode_id)
  raise "No transcript for episode #{episode_id}" unless transcript

  Log.info { "DubTranslator[#{dub_id}]: translating #{transcript.size} chars to #{language}" }
  translation = DeepLClient.translate(transcript, language)
  Log.info { "DubTranslator[#{dub_id}]: translation #{translation.size} chars" }

  DubbedEpisode.advance_to_synthesis(dub_id, translation)
  Log.info { "DubTranslator[#{dub_id}]: advanced to synthesis" }
rescue ex
  Log.error { "DubTranslator[#{dub_id}]: failed — #{ex.message}" }
  DubbedEpisode.set_failed(dub_id, ex.message || "Unknown error")
end
