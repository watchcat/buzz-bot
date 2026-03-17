module Assets
  # Computed once at startup from the latest mtime of CSS + JS.
  # Changes every time you restart after editing static files,
  # which forces browsers/WebViews to fetch fresh copies.
  VERSION = begin
    mtimes = ["public/css/app.css", "public/js/app.js", "public/js/miniplayer.js", "public/js/cache.js", "public/js/write-queue.js"].map do |path|
      File.info(path).modification_time.to_unix rescue 0_i64
    end
    mtimes.max.to_s
  end
end
