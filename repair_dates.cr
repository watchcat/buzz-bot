require "dotenv"
require "db"
require "pg"
require "xml"
require "http/client"

Dotenv.load if File.exists?(".env")

# Inline the fixed parser so this script is self-contained
def parse_rfc822(str : String) : Time?
  s = str.strip
    .sub(/\bUTC$/i, "+0000").sub(/\bGMT$/i, "+0000")
    .sub(/\bEST$/i, "-0500").sub(/\bEDT$/i, "-0400")
    .sub(/\bCST$/i, "-0600").sub(/\bCDT$/i, "-0500")
    .sub(/\bMST$/i, "-0700").sub(/\bMDT$/i, "-0600")
    .sub(/\bPST$/i, "-0800").sub(/\bPDT$/i, "-0700")
  [
    "%a, %d %b %Y %H:%M:%S %z",
    "%a, %b %d %Y %H:%M:%S %z",
    "%d %b %Y %H:%M:%S %z",
  ].each do |fmt|
    return Time.parse(s, fmt, Time::Location::UTC)
  rescue
  end
  nil
end

DB.open(ENV["DATABASE_URL"]) do |db|
  feeds = [] of {Int64, String}
  db.query_each(
    "SELECT DISTINCT f.id, f.url FROM feeds f
     JOIN episodes e ON e.feed_id = f.id
     WHERE e.published_at IS NULL"
  ) { |rs| feeds << {rs.read(Int64), rs.read(String)} }

  puts "Feeds with NULL published_at: #{feeds.size}"

  feeds.each do |feed_id, url|
    print "  Feed #{feed_id} #{url[0, 55]}... "
    begin
      resp = HTTP::Client.get(url)
      unless resp.success?
        puts "HTTP #{resp.status_code}"
        next
      end

      doc     = XML.parse(resp.body)
      channel = doc.first_element_child.try(&.first_element_child)
      unless channel
        puts "no channel"
        next
      end

      updated = 0
      channel.children.each do |node|
        next unless node.name == "item"
        guid    = node.xpath_node("guid").try(&.content) || node.xpath_node("link").try(&.content)
        pub_str = node.xpath_node("pubDate").try(&.content)
        next unless guid && pub_str
        published_at = parse_rfc822(pub_str)
        next unless published_at
        result = db.exec(
          "UPDATE episodes SET published_at = $1 WHERE feed_id = $2 AND guid = $3 AND published_at IS NULL",
          published_at, feed_id, guid
        )
        updated += result.rows_affected
      end
      puts "updated #{updated}"
    rescue ex
      puts "error: #{ex.message}"
    end
  end
end
puts "Done."
