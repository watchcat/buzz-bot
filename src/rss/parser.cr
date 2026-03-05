require "xml"
require "http/client"

module RSS
  struct ParsedFeed
    property url : String
    property title : String?
    property description : String?
    property image_url : String?
    property ttl_minutes : Int32?
    property episodes : Array(ParsedEpisode)

    def initialize(@url, @title, @description, @image_url, @ttl_minutes, @episodes)
    end
  end

  struct ParsedEpisode
    property guid : String
    property title : String
    property description : String?
    property audio_url : String
    property duration_sec : Int32?
    property published_at : Time?

    def initialize(@guid, @title, @description, @audio_url, @duration_sec, @published_at)
    end
  end

  def self.fetch_and_parse(url : String) : ParsedFeed
    response = HTTP::Client.get(url)
    raise "Failed to fetch feed: HTTP #{response.status_code}" unless response.success?
    parse(url, response.body)
  end

  def self.parse(url : String, xml_body : String) : ParsedFeed
    doc = XML.parse(xml_body)
    channel = doc.first_element_child.try(&.first_element_child)
    raise "Invalid RSS: no channel element" unless channel

    title = text_content(channel, "title")
    description = text_content(channel, "description")
    image_url = channel.xpath_node("image/url").try(&.content) ||
                channel.xpath_node("*[local-name()='image']/@href").try(&.content)
    ttl_minutes = text_content(channel, "ttl").try(&.to_i?)

    episodes = [] of ParsedEpisode
    channel.children.each do |node|
      next unless node.name == "item"
      episode = parse_item(node)
      episodes << episode if episode
    end

    ParsedFeed.new(url, title, description, image_url, ttl_minutes, episodes)
  end

  def self.parse_opml(xml_body : String) : Array(String)
    doc = XML.parse(xml_body)
    urls = [] of String
    doc.xpath_nodes("//outline[@type='rss']/@xmlUrl").each do |attr|
      urls << attr.content unless attr.content.empty?
    end
    # Also catch outlines without type attribute but with xmlUrl
    doc.xpath_nodes("//outline[@xmlUrl and not(@type)]/@xmlUrl").each do |attr|
      url = attr.content
      urls << url unless url.empty? || urls.includes?(url)
    end
    urls
  end

  private def self.parse_item(node : XML::Node) : ParsedEpisode?
    guid = text_content(node, "guid") || text_content(node, "link")
    title = text_content(node, "title")
    return nil unless guid && title

    # Audio URL from enclosure — upgrade http:// to https:// to avoid
    # mixed-content blocking when the app is served over HTTPS.
    audio_url = (node.xpath_node("enclosure[@type]/@url").try(&.content) ||
                 node.xpath_node("enclosure/@url").try(&.content) ||
                 node.xpath_node("*[local-name()='enclosure']/@url").try(&.content))
                .try { |u| u.starts_with?("http://") ? "https://" + u[7..] : u }
    return nil unless audio_url

    description = text_content(node, "description") ||
                  node.xpath_node("*[local-name()='summary']").try(&.content)

    duration_sec = parse_duration(
      node.xpath_node("*[local-name()='duration']").try(&.content)
    )

    pub_date_str = text_content(node, "pubDate")
    published_at = pub_date_str ? parse_rfc822(pub_date_str) : nil

    ParsedEpisode.new(guid, title, description, audio_url, duration_sec, published_at)
  end

  private def self.text_content(node : XML::Node, name : String) : String?
    node.xpath_node(name).try(&.content).presence
  end

  private def self.parse_duration(str : String?) : Int32?
    return nil unless str
    str = str.strip
    parts = str.split(":").map(&.to_i)
    case parts.size
    when 1 then parts[0]
    when 2 then parts[0] * 60 + parts[1]
    when 3 then parts[0] * 3600 + parts[1] * 60 + parts[2]
    else    nil
    end
  rescue
    nil
  end

  private def self.parse_rfc822(str : String) : Time?
    s = str.strip
    [
      "%a, %d %b %Y %H:%M:%S %z",
      "%d %b %Y %H:%M:%S %z",
    ].each do |fmt|
      return Time.parse(s, fmt, Time::Location::UTC)
    rescue
    end
    nil
  end
end
