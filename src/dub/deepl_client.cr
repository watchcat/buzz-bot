require "http/client"
require "uri"
require "json"

module DeepLClient
  def self.base_url : String
    Config.deepl_api_key.ends_with?(":fx") ?
      "https://api-free.deepl.com" :
      "https://api.deepl.com"
  end

  def self.translate(text : String, target_language : String) : String
    params = URI::Params.build do |p|
      p.add "text",        text
      p.add "target_lang", target_language.upcase
    end

    resp = HTTP::Client.post(
      "#{base_url}/v2/translate",
      headers: HTTP::Headers{
        "Authorization" => "DeepL-Auth-Key #{Config.deepl_api_key}",
        "Content-Type"  => "application/x-www-form-urlencoded",
      },
      body: params.to_s
    )
    raise "DeepL translate failed (#{resp.status_code}): #{resp.body}" unless resp.success?

    result = JSON.parse(resp.body)
    result["translations"]?
      .try(&.as_a?.try(&.first?))
      .try(&.["text"]?.try(&.as_s?)) ||
      raise "DeepL returned unexpected response: #{resp.body}"
  end
end
