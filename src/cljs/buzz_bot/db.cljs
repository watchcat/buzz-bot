(ns buzz-bot.db)

(def default-db
  {:view        :inbox
   :view-params {}
   :init-data   ""
   :theme       {}
   :inbox       {:episodes [] :loading? false
                 :filters  {:hide-listened? false :compact? false :excluded-feeds #{}}}
   :feeds       {:list [] :loading? false}
   :episodes    {:feed-id nil :list [] :loading? false :order :desc :offset 0 :has-more? false}
   :player      {:data nil :loading? false}
   :bookmarks   {:list [] :loading? false :query ""}
   :audio       {:episode-id nil :title "" :artist "" :artwork ""
                 :src "" :playing? false :current-time 0 :duration 0
                 :rate 1 :autoplay? false :pending? false}
   :saved-list  {:view nil :count 0}})
