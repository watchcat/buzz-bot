require "json"
require "../../models/dub_segment"
require "../../models/episode"

module Web::Routes::Subtitles
  def self.register
    get "/episodes/:id/subtitles" do |env|
      user = Auth.current_user(env)
      halt env, status_code: 401, response: "Unauthorized" unless user

      episode_id_raw = env.params.url["id"].to_i64?
      halt env, status_code: 400, response: %({"error":"invalid_id"}) unless episode_id_raw
      episode_id = episode_id_raw
      language   = env.params.query["language"]?

      cues = DubSegment.for_episode(episode_id, language)

      source_lang = Episode.original_language(episode_id)

      env.response.content_type = "application/json"
      next JSON.build do |j|
        j.object do
          j.field "source_lang", source_lang
          j.field "cues" do
            j.array do
              cues.each do |c|
                j.object do
                  j.field "idx",   c.idx
                  j.field "start", c.start_sec
                  j.field "end",   c.end_sec
                  j.field "text",  c.text
                  j.field "translation", c.translated_text if c.translated_text
                end
              end
            end
          end
        end
      end
    rescue ex
      Log.error { "Subtitles: #{ex.message}" }
      env.response.status_code = 500
      %({"error":"Internal error"})
    end
  end
end
