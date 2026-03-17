// ============================================================
// Telegram WebApp SDK init
// ============================================================
const tg = window.Telegram?.WebApp;

if (tg) {
  tg.ready();
  tg.expand();

  const params = tg.themeParams;
  if (params) {
    const root = document.documentElement.style;
    if (params.bg_color)           root.setProperty('--bg-color', params.bg_color);
    if (params.text_color)         root.setProperty('--text-color', params.text_color);
    if (params.hint_color)         root.setProperty('--hint-color', params.hint_color);
    if (params.link_color)         root.setProperty('--link-color', params.link_color);
    if (params.button_color)       root.setProperty('--button-color', params.button_color);
    if (params.button_text_color)  root.setProperty('--button-text-color', params.button_text_color);
    if (params.secondary_bg_color) root.setProperty('--secondary-bg', params.secondary_bg_color);
  }

  const initDataEl = document.getElementById('initData');
  if (initDataEl && tg.initData) {
    initDataEl.value = tg.initData;
  }
}

function getInitData() {
  return tg?.initData || document.getElementById('initData')?.value || '';
}

// Handle deep link from share: ?episode=ID in URL, or tg startapp param
(function handleDeepLink() {
  const fromUrl   = new URLSearchParams(window.location.search).get('episode');
  const fromStart = tg?.initDataUnsafe?.start_param || '';
  const episodeId = fromUrl || (fromStart.startsWith('ep_') ? fromStart.slice(3) : null);
  if (!episodeId) return;
  const main = document.getElementById('content');
  if (main) main.setAttribute('hx-get', `/episodes/${episodeId}/player?from=share`);
})();

// ============================================================
// PlayerBus — the audio engine lives in miniplayer.js (Preact bundle).
// Everything below that touches audio goes through this reference.
// ============================================================
const pb = window.playerBus;

// Autoplay-next when the current episode finishes
pb.audio.addEventListener('ended', () => maybePlayNext());

// Make showSubscribePrompt reachable from player-bus.js (called on speed up without premium)
window.showSubscribePrompt = showSubscribePrompt;

// ============================================================
// HTMX — inject initData header on every request
// ============================================================
const REVERSE_ORDER_KEY = 'buzz-feed-reverse';

document.addEventListener('htmx:configRequest', (event) => {
  const initData = getInitData();
  if (initData) event.detail.headers['X-Init-Data'] = initData;

  // Auto-inject saved order preference for feed episode list requests
  const path      = event.detail.path || '';
  const feedMatch = path.match(/[?&]feed_id=(\d+)/);
  if (feedMatch && !path.includes('order=')) {
    const reversed = localStorage.getItem(`${REVERSE_ORDER_KEY}-${feedMatch[1]}`) === 'true';
    if (reversed) event.detail.parameters['order'] = 'asc';
  }
});

document.addEventListener('htmx:responseError', (event) => {
  const status = event.detail.xhr.status;
  const target = event.detail.target;
  if (status === 401) {
    target.innerHTML = '<div class="error-msg">Please open this app from Telegram.</div>';
  } else {
    target.innerHTML = `<div class="error-msg">Something went wrong (${status}). Please try again.</div>`;
  }
});

// Tab management
function setActiveTab(btn) {
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
}

// ============================================================
// Play / Pause / Seek / Speed — thin wrappers over playerBus
// ============================================================
function togglePlayPause() {
  const audio = pb.audio;
  // If no audio is loaded yet (bar restored from previous session),
  // navigate to the player with autoplay rather than calling play() on empty src.
  if (audio.paused && (!audio.src || audio.src === window.location.href)) {
    const episodeId = pb.currentEpisode.value?.id;
    if (episodeId) {
      htmx.ajax('GET', `/episodes/${episodeId}/player?autoplay=1&from=inbox`, {
        target: '#content', swap: 'innerHTML',
      });
      return;
    }
  }
  pb.togglePlay();
}

function userPause()          { pb.userPause(); }
function seekRelative(delta)  { pb.seekRelative(delta); }
function cycleSpeed()         { pb.cycleSpeed(); }

function showSubscribePrompt() {
  if (tg?.showPopup) {
    tg.showPopup({
      title:   '⭐ Buzz-Bot Premium',
      message: 'Speed control (1.5× / 2×) and sending episodes to Telegram are Premium features.\n\nSubscribe for 100⭐/month.',
      buttons: [
        { id: 'sub',    type: 'default', text: 'Subscribe Now' },
        { id: 'cancel', type: 'cancel',  text: 'Not Now'       },
      ],
    }, id => { if (id === 'sub') openSubscribeBot(); });
  } else {
    openSubscribeBot();
  }
}

function openSubscribeBot() {
  const url = `https://t.me/${window.BOT_USERNAME}?start=subscribe`;
  if (tg?.openTelegramLink) tg.openTelegramLink(url);
  else window.open(url, '_blank');
}

// ============================================================
// Full-player controls (only present when player page is shown)
// ============================================================
const AUTOPLAY_KEY = 'buzz-autoplay';

function initFullPlayerControls() {
  const seekBar = document.getElementById('player-seek');
  if (!seekBar) return;

  // Clone to remove any stale listeners from the previous player page load
  const fresh = seekBar.cloneNode(true);
  seekBar.parentNode.replaceChild(fresh, seekBar);

  fresh.addEventListener('input', () => {
    fresh.style.setProperty('--pct', parseFloat(fresh.value).toFixed(2) + '%');
    if (pb.audio.duration) {
      const t = (fresh.value / 100) * pb.audio.duration;
      document.getElementById('player-current-time').textContent = formatTime(t);
    }
  });
  fresh.addEventListener('change', () => {
    if (pb.audio.duration) pb.seek((fresh.value / 100) * pb.audio.duration);
  });

  // Autoplay checkbox
  const checkbox = document.getElementById('autoplay-checkbox');
  if (checkbox) {
    checkbox.checked = localStorage.getItem(AUTOPLAY_KEY) === 'true';
    checkbox.addEventListener('change', () => {
      localStorage.setItem(AUTOPLAY_KEY, String(checkbox.checked));
    });
  }

  // Replace audio listeners on each player-page load to avoid accumulation
  if (window._playerAudioListeners) {
    const { timeupdate, durationchange, play, pause } = window._playerAudioListeners;
    pb.audio.removeEventListener('timeupdate',    timeupdate);
    pb.audio.removeEventListener('durationchange', durationchange);
    pb.audio.removeEventListener('play',           play);
    pb.audio.removeEventListener('pause',          pause);
  }
  const onTimeUpdate = () => updateSeekBar();
  const onPlayState  = () => {
    const btn = document.getElementById('player-play-pause');
    if (btn) btn.textContent = pb.audio.paused ? '▶' : '⏸';
  };
  pb.audio.addEventListener('timeupdate',    onTimeUpdate);
  pb.audio.addEventListener('durationchange', onTimeUpdate);
  pb.audio.addEventListener('play',           onPlayState);
  pb.audio.addEventListener('pause',          onPlayState);
  window._playerAudioListeners = { timeupdate: onTimeUpdate, durationchange: onTimeUpdate, play: onPlayState, pause: onPlayState };

  // Speed button — reactive to playbackRate signal
  if (window._speedEffectDispose) window._speedEffectDispose();
  window._speedEffectDispose = pb.effect(() => {
    const rate  = pb.playbackRate.value;
    const label = rate === 1 ? '1×' : `${rate}×`;
    const btn   = document.getElementById('player-speed-btn');
    if (btn) {
      btn.textContent = label;
      btn.classList.toggle('btn-speed--active', rate !== 1);
    }
  });

  // Cache progress — drives the green seek bar layer and hint text
  if (window._cacheEffectDispose) window._cacheEffectDispose();
  window._cacheEffectDispose = pb.effect(() => {
    _updateCacheFill(pb.cacheProgress.value);
  });

  updateSeekBar();
  onPlayState(); // sync play/pause button to current state immediately
}

function updateSeekBar() {
  const audio     = pb.audio;
  const seekBar   = document.getElementById('player-seek');
  const currentEl = document.getElementById('player-current-time');
  const durEl     = document.getElementById('player-duration');

  if (seekBar && audio.duration) {
    const pct = (audio.currentTime / audio.duration) * 100;
    seekBar.value = pct;
    seekBar.style.setProperty('--pct', pct.toFixed(2) + '%');
  }
  if (currentEl) currentEl.textContent = formatTime(audio.currentTime);
  if (durEl && audio.duration) durEl.textContent = formatTime(audio.duration);
}

function formatTime(sec) {
  if (!isFinite(sec) || sec < 0) return '--:--';
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = Math.floor(sec % 60);
  if (h > 0) return `${h}:${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}`;
  return `${m}:${String(s).padStart(2,'0')}`;
}

// ============================================================
// Autoplay next episode
// ============================================================
function maybePlayNext() {
  const checkbox = document.getElementById('autoplay-checkbox');
  if (!checkbox?.checked) return;
  const root   = document.getElementById('player-root');
  const nextId = root?.dataset.nextId;
  if (!nextId) return;
  const order = root?.dataset.order === 'asc' ? '&order=asc' : '';
  htmx.ajax('GET', `/episodes/${nextId}/player?autoplay=1${order}`, {
    target: '#content', swap: 'innerHTML',
  });
}

// ============================================================
// Cache progress UI (seek bar green layer + hint text)
// ============================================================
function _updateCacheFill(pct) {
  const seekBar = document.getElementById('player-seek');
  const hint    = document.getElementById('player-cache-hint');
  if (seekBar) seekBar.style.setProperty('--cache-pct', (pct * 100).toFixed(1) + '%');
  if (hint) {
    const caching      = pct > 0 && pct < 1;
    hint.hidden        = !caching;
    hint.textContent   = caching ? `Caching ${Math.round(pct * 100)}%` : '';
  }
}

// ============================================================
// Clipboard copy + toast feedback
// ============================================================
function copyToClipboard(text) {
  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(text).then(_showCopyToast).catch(_showCopyToast);
  } else {
    try {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.cssText = 'position:fixed;opacity:0;top:0;left:0';
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      document.body.removeChild(ta);
    } catch(e) {}
    _showCopyToast();
  }
}

function _showCopyToast() {
  let toast = document.getElementById('copy-toast');
  if (!toast) {
    toast = document.createElement('div');
    toast.id = 'copy-toast';
    toast.className = 'copy-toast';
    document.body.appendChild(toast);
  }
  toast.textContent = 'RSS URL copied';
  toast.classList.add('copy-toast--visible');
  clearTimeout(toast._hideTimer);
  toast._hideTimer = setTimeout(() => toast.classList.remove('copy-toast--visible'), 1500);
}

// ============================================================
// Filter state — per-page isolation
// ============================================================
const INBOX_HIDE_LISTENED_KEY = 'buzz-inbox-hide-listened';
const FEED_HIDE_LISTENED_KEY  = 'buzz-feed-hide-listened';
const FEED_FILTER_KEY         = 'buzz-inbox-excluded-feeds';
const COMPACT_KEY             = 'buzz-inbox-compact';

function isInboxPage() {
  return !!document.getElementById('compact-mode-cb');
}

function hideListenedKey() {
  return isInboxPage() ? INBOX_HIDE_LISTENED_KEY : FEED_HIDE_LISTENED_KEY;
}

function getExcludedFeeds() {
  try {
    const stored = localStorage.getItem(FEED_FILTER_KEY);
    if (stored) return new Set(JSON.parse(stored).map(String));
  } catch (e) {}
  return new Set();
}

function saveExcludedFeeds(set) {
  localStorage.setItem(FEED_FILTER_KEY, JSON.stringify([...set]));
}

function applyAllFilters() {
  const list = document.getElementById('episode-list');
  if (!list) return;

  const inbox         = isInboxPage();
  const hideListen    = localStorage.getItem(hideListenedKey()) === 'true';
  const excludedFeeds = inbox ? getExcludedFeeds() : new Set();
  const compact       = inbox && localStorage.getItem(COMPACT_KEY) === 'true';

  clearCompactGrouping(list);

  list.querySelectorAll('.episode-item').forEach(el => {
    const feedExcluded   = excludedFeeds.has(el.dataset.feedId);
    const listenedHidden = hideListen && el.classList.contains('listened');
    el.style.display = (feedExcluded || listenedHidden) ? 'none' : '';
  });

  if (compact) applyCompactGrouping(list);
}

function applyListenedFilter(hide) {
  localStorage.setItem(hideListenedKey(), hide ? 'true' : 'false');
  applyAllFilters();
}

// ============================================================
// Feed filter panel
// ============================================================
function updateFeedFilterBtn() {
  const btn = document.getElementById('feed-filter-btn');
  if (!btn) return;
  btn.classList.toggle('has-filter', getExcludedFeeds().size > 0);
}

function toggleFeedFilterPanel() {
  const panel = document.getElementById('inbox-filter-panel');
  const btn   = document.getElementById('feed-filter-btn');
  if (!panel) return;
  const nowOpen = panel.hidden;
  panel.hidden = !nowOpen;
  btn?.classList.toggle('active', nowOpen);
}

function onFeedFilterChange() {
  const excluded = new Set();
  document.querySelectorAll('.feed-filter-cb').forEach(cb => {
    if (!cb.checked) excluded.add(cb.dataset.feedId);
  });
  saveExcludedFeeds(excluded);
  updateFeedFilterBtn();
  applyAllFilters();
}

// ============================================================
// Compact mode
// ============================================================
function setCompactMode(compact) {
  localStorage.setItem(COMPACT_KEY, compact ? 'true' : 'false');
  applyAllFilters();
}

function clearCompactGrouping(list) {
  list.querySelectorAll('.compact-expand-btn').forEach(el => el.remove());
  list.querySelectorAll('.episode-item').forEach(el => {
    el.classList.remove('compact-hidden', 'compact-first');
    delete el.dataset.groupExpanded;
    delete el.dataset.groupCount;
  });
}

function applyCompactGrouping(list) {
  const visible = [...list.querySelectorAll('.episode-item')]
    .filter(el => el.style.display !== 'none');

  let i = 0;
  while (i < visible.length) {
    const feedId   = visible[i].dataset.feedId;
    let j = i + 1;
    while (j < visible.length && visible[j].dataset.feedId === feedId) j++;

    const group    = visible.slice(i, j);
    const siblings = group.slice(1);

    if (siblings.length > 0) {
      const first = group[0];
      first.classList.add('compact-first');
      first.dataset.groupCount    = group.length;
      first.dataset.groupExpanded = 'false';

      siblings.forEach(el => {
        el.classList.add('compact-hidden');
        el.style.display = 'none';
      });

      const btn = document.createElement('button');
      btn.className   = 'compact-expand-btn';
      btn.textContent = `+${siblings.length} more`;
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        toggleCompactGroup(first, siblings);
      });
      first.appendChild(btn);
    }

    i = j;
  }
}

function toggleCompactGroup(first, siblings) {
  const expanded = first.dataset.groupExpanded === 'true';
  siblings.forEach(el => {
    el.classList.toggle('compact-hidden', expanded);
    el.style.display = expanded ? 'none' : '';
  });
  first.dataset.groupExpanded = expanded ? 'false' : 'true';
  const btn = first.querySelector('.compact-expand-btn');
  if (btn) btn.textContent = expanded ? `+${siblings.length} more` : 'show less';
}

// ============================================================
// Restore all inbox state after HTMX swap
// ============================================================
function initInboxState() {
  const compactCb = document.getElementById('compact-mode-cb');
  if (compactCb) compactCb.checked = localStorage.getItem(COMPACT_KEY) === 'true';

  const listenedCb = document.getElementById('hide-listened-cb');
  if (listenedCb) listenedCb.checked = localStorage.getItem(hideListenedKey()) === 'true';

  const excluded = getExcludedFeeds();
  document.querySelectorAll('.feed-filter-cb').forEach(cb => {
    cb.checked = !excluded.has(cb.dataset.feedId);
  });

  updateFeedFilterBtn();
  applyAllFilters();
}

// ============================================================
// Feed episode list — reverse order toggle
// ============================================================
function setReverseOrder(checked) {
  const feedId = document.querySelector('#episode-list[data-feed-id]')?.dataset.feedId;
  if (!feedId) return;
  localStorage.setItem(`${REVERSE_ORDER_KEY}-${feedId}`, checked ? 'true' : 'false');
  const order = checked ? 'asc' : 'desc';
  htmx.ajax('GET', `/episodes?feed_id=${feedId}&order=${order}`, {
    target: '#content', swap: 'innerHTML',
  });
}

// ============================================================
// Description fold
// ============================================================
const DESC_COLLAPSE_THRESHOLD = 120;

function initDescriptionFold() {
  const desc   = document.querySelector('.player-description');
  const toggle = desc && document.getElementById(`player-desc-toggle-${desc.id.replace('player-desc-', '')}`);
  if (!desc || !toggle) return;
  if (desc.scrollHeight > DESC_COLLAPSE_THRESHOLD) {
    desc.classList.add('player-description--collapsed');
    toggle.hidden = false;
  }
}

function toggleDescription(episodeId) {
  const desc   = document.getElementById(`player-desc-${episodeId}`);
  const toggle = document.getElementById(`player-desc-toggle-${episodeId}`);
  if (!desc || !toggle) return;
  const nowCollapsed = desc.classList.toggle('player-description--collapsed');
  toggle.textContent = nowCollapsed ? 'Show more ▾' : 'Show less ▴';
}

// ============================================================
// Share episode
// ============================================================
function toggleSharePanel(episodeId) {
  const panel = document.getElementById(`share-panel-${episodeId}`);
  if (panel) panel.hidden = !panel.hidden;
}

function shareEpisode(episodeId, message) {
  const deepLink = `https://t.me/${window.BOT_USERNAME}?start=ep_${episodeId}`;
  const shareUrl = `https://t.me/share/url?url=${encodeURIComponent(deepLink)}&text=${encodeURIComponent(message.trim())}`;
  if (tg?.openTelegramLink) tg.openTelegramLink(shareUrl);
  else window.open(shareUrl, '_blank');
}

// ============================================================
// Episode description links — open in external browser
// ============================================================
document.addEventListener('click', (e) => {
  const link = e.target.closest('.player-description a');
  if (!link) return;
  const href = link.href;
  if (!href || href === '#' || href.startsWith('javascript:')) return;
  e.preventDefault();
  if (tg) tg.openLink(href);
  else window.open(href, '_blank', 'noopener');
});

// ============================================================
// HTMX lifecycle
// ============================================================
document.addEventListener('htmx:afterSwap', () => {
  const playerData = document.getElementById('player-data');
  if (playerData) {
    pb.load(playerData.dataset);
    initFullPlayerControls();
    initDescriptionFold();
  }
  initInboxState();
});
