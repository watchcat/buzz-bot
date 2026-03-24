require "http/client"
require "openssl/hmac"
require "digest/sha256"

module R2Storage
  REGION  = "auto"
  SERVICE = "s3"

  def self.put(key : String, data : Bytes, content_type : String = "audio/mpeg") : String
    bucket   = Config.r2_bucket
    account  = Config.r2_account_id
    host     = "#{bucket}.#{account}.r2.cloudflarestorage.com"
    path     = "/#{key}"

    datetime = Time.utc.to_s("%Y%m%dT%H%M%SZ")
    date     = datetime[0, 8]

    payload_hash = Digest::SHA256.hexdigest(String.new(data))

    canon_headers  = "content-type:#{content_type}\nhost:#{host}\n" \
                     "x-amz-content-sha256:#{payload_hash}\nx-amz-date:#{datetime}\n"
    signed_headers = "content-type;host;x-amz-content-sha256;x-amz-date"

    canonical_request = [
      "PUT", path, "",
      canon_headers, signed_headers, payload_hash,
    ].join("\n")

    scope = "#{date}/#{REGION}/#{SERVICE}/aws4_request"
    string_to_sign = [
      "AWS4-HMAC-SHA256", datetime, scope,
      Digest::SHA256.hexdigest(canonical_request),
    ].join("\n")

    k_date    = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, "AWS4#{Config.r2_secret_access_key}", date)
    k_region  = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, k_date, REGION)
    k_service = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, k_region, SERVICE)
    k_signing = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, k_service, "aws4_request")
    signature = OpenSSL::HMAC.hexdigest(OpenSSL::Algorithm::SHA256, k_signing, string_to_sign)

    auth_header = "AWS4-HMAC-SHA256 Credential=#{Config.r2_access_key_id}/#{scope}, " \
                  "SignedHeaders=#{signed_headers}, Signature=#{signature}"

    resp = HTTP::Client.put(
      "https://#{host}#{path}",
      headers: HTTP::Headers{
        "Host"                 => host,
        "Content-Type"         => content_type,
        "x-amz-date"           => datetime,
        "x-amz-content-sha256" => payload_hash,
        "Authorization"        => auth_header,
      },
      body: String.new(data)
    )
    raise "R2 upload failed (#{resp.status_code}): #{resp.body[0, 200]}" unless resp.success?

    "#{Config.r2_public_url}/#{key}"
  end
end
