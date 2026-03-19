module Assets
  # Computed once at startup from the mtime of the compiled JS bundle.
  # Changes every deploy (Docker build timestamp), forcing browsers to
  # fetch fresh copies.
  VERSION = begin
    File.info("public/js/main.js").modification_time.to_unix.to_s
  rescue
    Time.utc.to_unix.to_s
  end
end
