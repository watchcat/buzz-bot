require "json"
require "../models/feed"
require "../models/episode"
require "../models/user_feed"

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
end
