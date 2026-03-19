require "json"

module Web
  # Enriched episode for list responses (inbox, feed episode list, bookmarks).
  struct EpisodeJson
    include JSON::Serializable

    property id               : Int64
    property title            : String
    property audio_url        : String
    property description      : String?
    property published_at     : Time?
    property duration_seconds : Int32?
    property feed_id          : Int64
    property feed_title       : String
    property feed_image_url   : String?
    property listened         : Bool
    property progress_seconds : Int32
    property liked            : Bool

    def initialize(ep : Episode, feed_title : String, feed_image_url : String?,
                   ue : UserEpisode?)
      @id               = ep.id
      @title            = ep.title
      @audio_url        = ep.audio_url
      @description      = ep.description
      @published_at     = ep.published_at
      @duration_seconds = ep.duration_sec
      @feed_id          = ep.feed_id
      @feed_title       = feed_title
      @feed_image_url   = feed_image_url
      @listened         = ue.try(&.completed) || false
      @progress_seconds = ue.try(&.progress_seconds) || 0
      @liked            = ue.try(&.liked) == true
    end
  end

  # Rec item (flat struct for recommendations in player response)
  struct RecJson
    include JSON::Serializable
    property id         : Int64
    property title      : String
    property feed_id    : Int64
    property feed_title : String

    def initialize(ep : Episode, feed_title : String)
      @id         = ep.id
      @title      = ep.title
      @feed_id    = ep.feed_id
      @feed_title = feed_title
    end
  end

  # Build a batch of EpisodeJson from a list of episodes.
  # Fetches feed info and user_episode data in bulk.
  def self.build_episode_list(episodes : Array(Episode), user_id : Int64) : Array(EpisodeJson)
    return [] of EpisodeJson if episodes.empty?

    # Batch-fetch feeds
    feed_ids  = episodes.map(&.feed_id).uniq
    feeds_map = feed_ids.each_with_object({} of Int64 => Feed) do |fid, h|
      Feed.find(fid).try { |f| h[fid] = f }
    end

    # Batch-fetch user_episodes
    ep_ids = episodes.map(&.id)
    ue_map = UserEpisode.find_batch(user_id, ep_ids)

    episodes.map do |ep|
      feed = feeds_map[ep.feed_id]?
      EpisodeJson.new(
        ep,
        feed.try(&.title) || "",
        feed.try(&.image_url),
        ue_map[ep.id]?
      )
    end
  end
end
