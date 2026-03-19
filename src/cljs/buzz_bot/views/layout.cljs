(ns buzz-bot.views.layout
  (:require [re-frame.core :as rf]
            [buzz-bot.subs :as subs]
            [buzz-bot.events :as events]
            [buzz-bot.views.miniplayer :as miniplayer]
            [buzz-bot.views.inbox :as inbox]
            [buzz-bot.views.feeds :as feeds]
            [buzz-bot.views.episodes :as episodes]
            [buzz-bot.views.player :as player]
            [buzz-bot.views.bookmarks :as bookmarks]))

(defn- tab-btn [label view-kw current-view]
  [:button.tab-btn
   {:class    (when (= current-view view-kw) "active")
    :on-click #(rf/dispatch [::events/navigate view-kw])}
   label])

(defn root []
  (let [view @(rf/subscribe [::subs/view])]
    [:div#app
     [:div.app-container
      [:nav.tab-bar
       [tab-btn "📥 Inbox"     :inbox     view]
       [tab-btn "📻 Feeds"     :feeds     view]
       [tab-btn "🔖 Bookmarks" :bookmarks view]]
      [:main#content
       (case view
         :inbox     [inbox/view]
         :feeds     [feeds/view]
         :episodes  [episodes/view]
         :player    [player/view]
         :bookmarks [bookmarks/view]
         [:div.loading "Loading..."])]]
     [miniplayer/bar]]))
