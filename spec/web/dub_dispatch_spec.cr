# spec/web/dub_dispatch_spec.cr
require "../spec_helper"
require "../../src/web/dub_dispatch"

describe Web::DubDispatch do
  it "builds a dub dispatch payload" do
    json = JSON.parse(Web::DubDispatch.dub_payload(
      "run1", 42_i64, 456_i64, "https://a.mp3", "es", 0.15, "https://cb/internal/dub_result"))
    json["run_id"].should eq("run1")
    json["workflow_type"].should eq("dub")
    json["dub_id"].should eq(42)
    json["episode_id"].should eq(456)
    json["audio_url"].should eq("https://a.mp3")
    json["language"].should eq("es")
    json["bg_volume"].should eq(0.15)
    json["callback_url"].should eq("https://cb/internal/dub_result")
  end

  it "builds a transcribe dispatch payload (no dub_id/language)" do
    json = JSON.parse(Web::DubDispatch.transcribe_payload(
      "run2", 456_i64, "https://a.mp3", "https://cb/internal/transcript_result"))
    json["workflow_type"].should eq("transcribe")
    json["run_id"].should eq("run2")
    json["episode_id"].should eq(456)
    json["audio_url"].should eq("https://a.mp3")
    json["callback_url"].should eq("https://cb/internal/transcript_result")
    json.as_h.has_key?("dub_id").should be_false
  end
end
