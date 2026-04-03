(ns buzz-bot.views.utils
  (:require [re-frame.db]))

(defn img-proxy
  "Wrap an external image URL through /img-proxy so it passes Telegram's
   restrictive img-src CSP (which only allows 'self' and a few other origins).
   Bypassed when the img_proxy feature flag is disabled."
  [url]
  (when url
    (if (get-in @re-frame.db/app-db [:flags "img_proxy"] true)
      (str "/img-proxy?url=" (js/encodeURIComponent url))
      url)))
