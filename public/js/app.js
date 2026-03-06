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

const LAST_EPISODE_KEY      = 'buzz-last-episode-id';
const LAST_EPISODE_META_KEY = 'buzz-last-episode-meta';

// Restore now-playing bar from the previous session (UI only — no audio loaded).
// Tapping the bar navigates to the player page as usual.
(function restoreNowPlayingBar() {
  const savedId = localStorage.getItem(LAST_EPISODE_KEY);
  if (!savedId) return;
  let meta = {};
  try { meta = JSON.parse(localStorage.getItem(LAST_EPISODE_META_KEY) || '{}'); } catch (e) {}
  const bar = document.getElementById('now-playing');
  if (!bar) return;
  bar.hidden = false;
  bar.dataset.episodeId = savedId;
  document.getElementById('now-playing-title').textContent   = meta.title   || '';
  document.getElementById('now-playing-podcast').textContent = meta.podcast  || '';
  const artEl = document.getElementById('now-playing-artwork');
  if (artEl) {
    if (meta.artwork) {
      artEl.style.backgroundImage = `url('${meta.artwork}')`;
      artEl.textContent = '';
    } else {
      artEl.style.backgroundImage = '';
      artEl.textContent = '🎙';
    }
  }
})();

// ============================================================
// HTMX — inject initData header on every request
// ============================================================
document.addEventListener('htmx:configRequest', (event) => {
  const initData = getInitData();
  if (initData) {
    event.detail.headers['X-Init-Data'] = initData;
  }
});

// HTMX error handling
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
// Persistent audio — single element in layout, never destroyed
// ============================================================
const audio = document.getElementById('episode-audio');
let progressTimer = null;
const AUTOPLAY_KEY = 'buzz-autoplay';

// Attach all audio event listeners once at page load
audio.addEventListener('play', () => {
  ensureAudioContext();
  updatePlayPauseButtons(true);
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
  syncPositionState();
});

audio.addEventListener('pause', () => {
  updatePlayPauseButtons(false);
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
  flushProgress();
});

audio.addEventListener('ended', () => {
  updatePlayPauseButtons(false);
  flushProgress(true);
  maybePlayNext();
});

audio.addEventListener('timeupdate', () => {
  updateSeekBar();
  if (progressTimer) return;
  progressTimer = setTimeout(() => {
    progressTimer = null;
    if (!audio.dataset.episodeId) return;
    saveProgress(
      audio.dataset.episodeId,
      Math.floor(audio.currentTime),
      audio.duration > 0 && (audio.duration - audio.currentTime) < 30
    );
  }, 5000);
});

audio.addEventListener('durationchange', () => {
  syncPositionState();
  updateSeekBar();
});

audio.addEventListener('loadedmetadata', () => updateSeekBar());

// Track whether audio was playing when we left the foreground so we can
// restore it if the WebView suspended playback while in the background.
let wasPlayingBeforeBackground = false;

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    wasPlayingBeforeBackground = !audio.paused;
  } else {
    // Resume Web Audio context (may have been suspended by the system)
    if (audioCtx?.state === 'suspended') audioCtx.resume();
    // If the WebView paused the audio element while backgrounded, restart it
    if (wasPlayingBeforeBackground && audio.paused) {
      audio.play().catch(() => {});
    }
  }
});

// ============================================================
// Load / switch episode into persistent audio
// ============================================================
function loadEpisodeIntoPlayer(playerData) {
  const newId    = playerData.dataset.episodeId;
  const src      = playerData.dataset.src;
  const start    = parseInt(playerData.dataset.start  || '0', 10);
  const autoplay = playerData.dataset.autoplay === '1';
  const title    = playerData.dataset.title   || '';
  const artist   = playerData.dataset.artist  || '';
  const artwork  = playerData.dataset.artwork || '';

  // Show now-playing bar and store episode for tap-to-return
  const bar = document.getElementById('now-playing');
  if (bar) {
    bar.hidden = false;
    bar.dataset.episodeId = newId;
  }
  document.getElementById('now-playing-title')?.textContent !== undefined &&
    (document.getElementById('now-playing-title').textContent = title);
  document.getElementById('now-playing-podcast')?.textContent !== undefined &&
    (document.getElementById('now-playing-podcast').textContent = artist);

  const artEl = document.getElementById('now-playing-artwork');
  if (artEl) {
    if (artwork) {
      artEl.style.backgroundImage = `url(${CSS.escape ? "'" + artwork + "'" : artwork})`;
      artEl.textContent = '';
    } else {
      artEl.style.backgroundImage = '';
      artEl.textContent = '🎙';
    }
  }

  if (audio.dataset.episodeId !== newId) {
    // New episode — reload audio
    if (progressTimer) { clearTimeout(progressTimer); progressTimer = null; }
    audio.dataset.episodeId = newId;
    // Persist so the now-playing bar is restored on next app launch
    localStorage.setItem(LAST_EPISODE_KEY, newId);
    localStorage.setItem(LAST_EPISODE_META_KEY, JSON.stringify({ title, podcast: artist, artwork }));
    // Upgrade http:// → https:// to avoid mixed-content blocking on HTTPS pages
    audio.src = src.replace(/^http:\/\//i, 'https://');
    audio.load();
    audio.addEventListener('loadedmetadata', () => {
      if (start > 0) audio.currentTime = start;
      if (autoplay) audio.play().catch(() => {});
    }, { once: true });
    setupMediaSession({ title, artist, artwork });
  }

  // Wire up the full-player controls that just appeared in #content
  initFullPlayerControls();
  syncPlayPauseAll();
}

// ============================================================
// Full-player controls (only present when player page is shown)
// ============================================================
function initFullPlayerControls() {
  const seekBar = document.getElementById('player-seek');
  if (!seekBar) return;

  // Remove any leftover listeners by replacing the element clone
  const fresh = seekBar.cloneNode(true);
  seekBar.parentNode.replaceChild(fresh, seekBar);

  fresh.addEventListener('input', () => {
    // Live preview position while dragging
    fresh.style.setProperty('--pct', parseFloat(fresh.value).toFixed(2) + '%');
    if (audio.duration) {
      const previewTime = (fresh.value / 100) * audio.duration;
      document.getElementById('player-current-time').textContent = formatTime(previewTime);
    }
  });
  fresh.addEventListener('change', () => {
    if (audio.duration) audio.currentTime = (fresh.value / 100) * audio.duration;
  });

  // Autoplay checkbox
  const checkbox = document.getElementById('autoplay-checkbox');
  if (checkbox) {
    checkbox.checked = localStorage.getItem(AUTOPLAY_KEY) === 'true';
    checkbox.addEventListener('change', () => {
      localStorage.setItem(AUTOPLAY_KEY, String(checkbox.checked));
    });
  }

  updateSeekBar();
}

function updateSeekBar() {
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
// Play / Pause / Seek
// ============================================================
function togglePlayPause() {
  if (audio.paused) {
    // If no audio is loaded yet (restored bar from previous session),
    // navigate to the player with autoplay rather than calling play() on an empty element.
    if (!audio.src || audio.src === window.location.href) {
      const episodeId = document.getElementById('now-playing')?.dataset.episodeId;
      if (episodeId) {
        htmx.ajax('GET', `/episodes/${episodeId}/player?autoplay=1&from=inbox`, {
          target: '#content',
          swap:   'innerHTML',
        });
        return;
      }
    }
    audio.play().catch(() => {});
  } else {
    audio.pause();
  }
}

function seekRelative(delta) {
  audio.currentTime = Math.max(0, Math.min(audio.duration || 0, audio.currentTime + delta));
  syncPositionState();
}

function updatePlayPauseButtons(playing) {
  const icon = playing ? '⏸' : '▶';
  const ids = ['now-playing-playpause', 'player-play-pause'];
  ids.forEach(id => {
    const btn = document.getElementById(id);
    if (btn) btn.textContent = icon;
  });
}

function syncPlayPauseAll() {
  updatePlayPauseButtons(!audio.paused);
}

// ============================================================
// Now-playing bar tap → navigate to full player
// ============================================================
document.getElementById('now-playing-tap')?.addEventListener('click', () => {
  const episodeId = document.getElementById('now-playing')?.dataset.episodeId;
  if (!episodeId) return;
  htmx.ajax('GET', `/episodes/${episodeId}/player`, {
    target: '#content',
    swap:   'innerHTML',
  });
});

// ============================================================
// Autoplay next episode
// ============================================================
function maybePlayNext() {
  const checkbox = document.getElementById('autoplay-checkbox');
  if (!checkbox?.checked) return;
  const nextId = document.getElementById('player-root')?.dataset.nextId;
  if (!nextId) return;
  htmx.ajax('GET', `/episodes/${nextId}/player?autoplay=1`, {
    target: '#content',
    swap:   'innerHTML',
  });
}

// ============================================================
// Progress saving
// ============================================================
function flushProgress(completed = false) {
  if (progressTimer) { clearTimeout(progressTimer); progressTimer = null; }
  if (!audio.dataset.episodeId) return;
  saveProgress(audio.dataset.episodeId, Math.floor(audio.currentTime), completed);
}

function saveProgress(episodeId, seconds, completed) {
  fetch(`/episodes/${episodeId}/progress`, {
    method:  'PUT',
    headers: { 'Content-Type': 'application/json', 'X-Init-Data': getInitData() },
    body:    JSON.stringify({ seconds, completed }),
  }).catch(err => console.warn('Progress save failed:', err));
}

// ============================================================
// AudioContext — keep alive across background/foreground
// ============================================================
let audioCtx = null;

function ensureAudioContext() {
  // AudioContext is created and resumed here solely to unlock audio on
  // mobile devices that block playback until a user-gesture context exists.
  // DO NOT connect the audio element via createMediaElementSource() —
  // doing so routes audio through the Web Audio graph, and if the context
  // is suspended (common in WebViews) audio plays silently with no output.
  if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  if (audioCtx.state === 'suspended') audioCtx.resume();
}

// ============================================================
// Media Session API
// ============================================================
function setupMediaSession({ title, artist, artwork }) {
  if (!('mediaSession' in navigator)) return;
  navigator.mediaSession.metadata = new MediaMetadata({
    title,
    artist,
    artwork: artwork ? [
      { src: artwork, sizes: '512x512', type: 'image/jpeg' },
    ] : [],
  });
  navigator.mediaSession.setActionHandler('play',         () => audio.play().catch(() => {}));
  navigator.mediaSession.setActionHandler('pause',        () => audio.pause());
  // 'stop' is sent by many Bluetooth headsets and system media controls
  // instead of (or in addition to) 'pause'
  navigator.mediaSession.setActionHandler('stop',         () => audio.pause());
  navigator.mediaSession.setActionHandler('seekbackward', (d) => seekRelative(-(d.seekOffset ?? 10)));
  navigator.mediaSession.setActionHandler('seekforward',  (d) => seekRelative(+(d.seekOffset ?? 30)));
  navigator.mediaSession.setActionHandler('seekto', (d) => {
    audio.currentTime = d.seekTime;
    syncPositionState();
  });
}

function syncPositionState() {
  if (!('mediaSession' in navigator) || !navigator.mediaSession.setPositionState) return;
  if (!audio.duration || !isFinite(audio.duration)) return;
  navigator.mediaSession.setPositionState({
    duration:     audio.duration,
    playbackRate: audio.playbackRate,
    position:     Math.min(audio.currentTime, audio.duration),
  });
}

// ============================================================
// Hardware media key fallback for Android WebView
//
// Android WebView deliberately disables the Web MediaSession API
// (Chromium bug #678979), so setActionHandler() never fires for
// Bluetooth headset buttons. Two fallback paths are tried:
//
// 1. Keyboard events: some headsets dispatch play/pause as a
//    MediaPlayPause key event (keyCode 179) to the focused window.
//    We listen on both keydown AND keyup because certain BT devices
//    only fire one of the two.
//
// 2. keyCode fallback: e.key may be 'Unidentified' in some WebViews
//    even when the keyCode is the correct media value. Handle the
//    numeric keyCodes as a secondary check.
// ============================================================
function handleMediaKey(e) {
  // keyCode values: 179 = MediaPlayPause, 175 = MediaPlay,
  // 19 = MediaPause, 178 = MediaStop (standard JS media keyCodes)
  const key = e.key;
  const code = e.keyCode;

  const isPlayPause = key === 'MediaPlayPause' || code === 179;
  const isPlay      = key === 'MediaPlay'      || code === 175;
  const isPause     = key === 'MediaPause'     || code === 19;
  const isStop      = key === 'MediaStop'      || code === 178;

  if (isPlayPause || isPlay || isPause || isStop) {
    e.preventDefault();
    if (isPlayPause) {
      togglePlayPause();
    } else if (isPlay) {
      if (audio.paused) audio.play().catch(() => {});
    } else {
      if (!audio.paused) audio.pause();
    }
  }
}

// Listen on both keydown and keyup — BT headset behaviour varies by device
document.addEventListener('keydown', handleMediaKey);
document.addEventListener('keyup',   handleMediaKey);

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
// Filter state — per-page isolation
// ============================================================
const INBOX_HIDE_LISTENED_KEY = 'buzz-inbox-hide-listened';
const FEED_HIDE_LISTENED_KEY  = 'buzz-feed-hide-listened';
const FEED_FILTER_KEY         = 'buzz-inbox-excluded-feeds';
const COMPACT_KEY             = 'buzz-inbox-compact';

// True only when the inbox tab content is active (has compact-mode toggle)
function isInboxPage() {
  return !!document.getElementById('compact-mode-cb');
}

// Return the correct hide-listened key for the current page
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

// Unified filter application: feed filter → listened filter → compact grouping.
// Compact mode and feed filter only apply when on the inbox page.
function applyAllFilters() {
  const list = document.getElementById('episode-list');
  if (!list) return;

  const inbox         = isInboxPage();
  const hideListen    = localStorage.getItem(hideListenedKey()) === 'true';
  const excludedFeeds = inbox ? getExcludedFeeds() : new Set();
  const compact       = inbox && localStorage.getItem(COMPACT_KEY) === 'true';

  // 1. Clear any previous compact grouping
  clearCompactGrouping(list);

  // 2. Apply base visibility: feed filter + listened filter
  list.querySelectorAll('.episode-item').forEach(el => {
    const feedExcluded   = excludedFeeds.has(el.dataset.feedId);
    const listenedHidden = hideListen && el.classList.contains('listened');
    el.style.display = (feedExcluded || listenedHidden) ? 'none' : '';
  });

  // 3. Compact grouping on top — inbox only
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
  // Work only on currently visible items (not hidden by other filters)
  const visible = [...list.querySelectorAll('.episode-item')]
    .filter(el => el.style.display !== 'none');

  let i = 0;
  while (i < visible.length) {
    const feedId = visible[i].dataset.feedId;
    let j = i + 1;
    while (j < visible.length && visible[j].dataset.feedId === feedId) j++;

    const group    = visible.slice(i, j);
    const siblings = group.slice(1);

    if (siblings.length > 0) {
      const first = group[0];
      first.classList.add('compact-first');
      first.dataset.groupCount    = group.length;
      first.dataset.groupExpanded = 'false';

      // Hide the rest of the group
      siblings.forEach(el => {
        el.classList.add('compact-hidden');
        el.style.display = 'none';
      });

      // Inject expand button into first item
      const btn = document.createElement('button');
      btn.className   = 'compact-expand-btn';
      btn.textContent = `+${siblings.length} more`;
      btn.addEventListener('click', (e) => {
        e.stopPropagation(); // don't trigger hx-get on the parent li
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
  // Restore compact toggle
  const compactCb = document.getElementById('compact-mode-cb');
  if (compactCb) compactCb.checked = localStorage.getItem(COMPACT_KEY) === 'true';

  // Restore listened toggle (uses page-specific key)
  const listenedCb = document.getElementById('hide-listened-cb');
  if (listenedCb) listenedCb.checked = localStorage.getItem(hideListenedKey()) === 'true';

  // Restore feed filter checkboxes
  const excluded = getExcludedFeeds();
  document.querySelectorAll('.feed-filter-cb').forEach(cb => {
    cb.checked = !excluded.has(cb.dataset.feedId);
  });

  // Reflect active-filter state on the button (dot badge)
  updateFeedFilterBtn();

  // Apply all filters (no-op if no episode list is present)
  applyAllFilters();
}

// ============================================================
// HTMX lifecycle
// ============================================================
document.addEventListener('htmx:afterSwap', () => {
  const playerData = document.getElementById('player-data');
  if (playerData) {
    loadEpisodeIntoPlayer(playerData);
  } else {
    syncPlayPauseAll();
  }

  initInboxState();
});
