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
   :player      {:data nil :loading? false :send-status nil}
   :bookmarks   {:list [] :loading? false :query ""}
   :search      {:query "" :results [] :loading? false :subscribed-urls #{}}
   :audio       {:episode-id nil :title "" :artist "" :artwork ""
                 :src "" :playing? false :current-time 0 :duration 0
                 :rate 1 :autoplay? false :pending? false}
   :saved-list  {:view nil :count 0}
   :cache       {:cached-ids  []   ;; most-recent first, max 5
                 :in-progress {}   ;; ep-id (string) → {:bytes-downloaded N :bytes-total N}
                 :blob-urls   {}}}) ;; ep-id (string) → blob URL string
