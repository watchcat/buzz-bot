# src/web/dub_dispatch.cr
require "json"

# Pure builders for the orchestrator POST /dispatch request bodies. No I/O —
# unit-tested in isolation; the routes (dub.cr, transcribe.cr) post the result.
module Web::DubDispatch
  def self.dub_payload(run_id : String, dub_id : Int64, episode_id : Int64,
                       audio_url : String, language : String, bg_volume : Float64,
                       callback_url : String) : String
    {
      run_id:        run_id,
      workflow_type: "dub",
      dub_id:        dub_id,
      episode_id:    episode_id,
      audio_url:     audio_url,
      language:      language,
      bg_volume:     bg_volume,
      callback_url:  callback_url,
    }.to_json
  end

  def self.transcribe_payload(run_id : String, episode_id : Int64,
                              audio_url : String, callback_url : String) : String
    {
      run_id:        run_id,
      workflow_type: "transcribe",
      episode_id:    episode_id,
      audio_url:     audio_url,
      callback_url:  callback_url,
    }.to_json
  end
end
