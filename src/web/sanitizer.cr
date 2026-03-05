module Sanitizer
  # These elements (plus their content) are stripped entirely.
  STRIP_ELEMENTS = %w[script style iframe object embed form audio video
                      input button select textarea meta link]

  # Sanitize podcast episode description HTML.
  # Strips dangerous elements/attributes while preserving links,
  # formatting, and images that are normal in RSS episode notes.
  def self.podcast_description(html : String) : String
    result = html

    # Remove dangerous block elements and everything inside them
    STRIP_ELEMENTS.each do |tag|
      result = result.gsub(/<#{tag}[\s\S]*?<\/#{tag}>/i, "")
      result = result.gsub(/<#{tag}[^>]*\/?>/i, "")
    end

    # Strip event handler attributes (onclick, onload, onerror, …)
    result = result.gsub(/\s+on\w+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/i, "")

    # Neutralize javascript: URIs in href/src
    result = result.gsub(/\b(href|src)\s*=\s*"javascript:[^"]*"/i, %(\\1="#"))
    result = result.gsub(/\b(href|src)\s*=\s*'javascript:[^']*'/i, %(\\1='#'))

    # Upgrade http:// → https:// in src/href to avoid mixed-content blocks
    result = result.gsub(/\b(src|href)\s*=\s*"http:\/\//i) { "#{$~[1]}=\"https://" }
    result = result.gsub(/\b(src|href)\s*=\s*'http:\/\//i) { "#{$~[1]}='https://" }

    result
  end
end
