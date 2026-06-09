# src/web/routes/transcript_result.cr
require "json"
require "../../models/dub_segment"
require "../../models/episode"
require "../../models/transcript_job"

module Web::Routes::TranscriptResult
  private struct Result
    include JSON::Serializable
    getter episode_id  : Int64
    getter source_lang : String?
    getter segments    : Array(JSON::Any)?
  end

  def self.register
    # Internal endpoint — called by the orchestrator, not the Mini App.
    post "/internal/transcript_result" do |env|
      body   = env.request.body.try(&.gets_to_end) || ""
      result = Result.from_json(body)
      ep_id  = result.episode_id

      if (src = result.source_lang.presence)
        Episode.save_original_language(ep_id, src)
        if (segs = result.segments) && !segs.empty?
          begin
            DubSegment.bulk_upsert(ep_id, src, segs)
            Log.info { "TranscriptResult[ep=#{ep_id}]: persisted #{segs.size} segments (#{src})" }
          rescue ex
            Log.warn { "TranscriptResult[ep=#{ep_id}]: persist failed — #{ex.message}" }
          end
        end
      end

      TranscriptJob.set_done(ep_id)
      env.response.content_type = "application/json"
      {ok: true}.to_json
    end
  end
end
