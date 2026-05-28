require "json"
require "../models/feed"
require "../models/episode"
require "../models/user_feed"
require "../bot/audio_sender"
require "./notify"

# Delivery::Dispatch — fans episodes out to subscribers per their delivery_mode.
#
# `eligible_targets` is the pure heart of the module: given subscriber and
# episode projections, it computes which (subscriber, episode) combinations
# should actually receive a Telegram delivery. Backfill protection lives here:
# only episodes published AFTER the user subscribed are delivered.
#
# `fanout` (added in the next task) wires this to the real models + side
# effects (spawn per target, call Notify or AudioSender by mode).
module Delivery::Dispatch
  record Subscriber,
    user_id       : Int64,
    telegram_id   : Int64,
    mode          : String,
    subscribed_at : Time

  record EpisodeRef,
    id           : Int64,
    published_at : Time?,
    audio_url    : String

  record Target,
    subscriber : Subscriber,
    episode    : EpisodeRef

  def self.eligible_targets(subscribers : Array(Subscriber), episodes : Array(EpisodeRef)) : Array(Target)
    out = [] of Target
    subscribers.each do |sub|
      next if sub.mode == "off"
      episodes.each do |ep|
        next if ep.audio_url.empty?
        pub = ep.published_at
        next if pub.nil?
        next unless sub.subscribed_at < pub
        out << Target.new(subscriber: sub, episode: ep)
      end
    end
    out
  end

  # Fanout entry called from FeedRefresher after a refresh batch. Builds
  # subscriber + episode projections, runs the eligibility filter, and spawns
  # one fiber per target — same fire-and-forget pattern used for /episodes/:id/send.
  def self.fanout(feed : Feed, episodes : Array(Episode))
    return if episodes.empty?

    subs = UserFeed.delivery_subscribers_for(feed.id)
    return if subs.empty?

    sub_refs = subs.map do |s|
      Subscriber.new(
        user_id: s.user_id, telegram_id: s.telegram_id,
        mode: s.mode, subscribed_at: s.subscribed_at,
      )
    end

    ep_index = episodes.each_with_object({} of Int64 => Episode) { |e, h| h[e.id] = e }
    ep_refs  = episodes.map do |e|
      EpisodeRef.new(id: e.id, published_at: e.published_at, audio_url: e.audio_url)
    end

    targets = eligible_targets(sub_refs, ep_refs)
    return if targets.empty?

    Log.info { "Delivery::Dispatch[feed=#{feed.id}]: #{targets.size} targets across #{episodes.size} episodes" }

    targets.each do |target|
      ep = ep_index[target.episode.id]
      sub = target.subscriber
      spawn(name: "delivery-#{sub.user_id}-#{ep.id}") do
        case sub.mode
        when "notify"
          Delivery::Notify.send(sub.telegram_id, feed, ep)
        when "mp3"
          # Caption appears as a text line below the audio bubble.
          # AudioSender's title/performer fields already populate the
          # bubble itself; the caption adds the publish date.
          caption = build_mp3_caption(feed, ep)
          AudioSender.send_to_user(sub.telegram_id, ep, feed, caption: caption)
        end
      end
    end
  end

  # Pure helper — extracted so it could be tested if desired. Format:
  # "Feed Title · May 28, 2026" (date omitted when published_at is nil).
  private MP3_MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]
  private def self.build_mp3_caption(feed : Feed, ep : Episode) : String?
    title = feed.title || "Podcast"
    if (pub = ep.published_at)
      "#{title} · #{MP3_MONTHS[pub.month - 1]} #{pub.day}, #{pub.year}"
    else
      title
    end
  end
end
