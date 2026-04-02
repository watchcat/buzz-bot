(ns buzz-bot.views.utils)

(defn img-proxy
  "Wrap an external image URL through /img-proxy so it passes Telegram's
   restrictive img-src CSP (which only allows 'self' and a few other origins)."
  [url]
  (when url
    (str "/img-proxy?url=" (js/encodeURIComponent url))))
