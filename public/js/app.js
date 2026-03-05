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

// Resume after backgrounding
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && audioCtx?.state === 'suspended') audioCtx.resume();
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
  if (audio.paused) audio.play().catch(() => {});
  else              audio.pause();
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
  navigator.mediaSession.setActionHandler('play',         () => audio.play());
  navigator.mediaSession.setActionHandler('pause',        () => audio.pause());
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
// Listened filter
// ============================================================
const HIDE_LISTENED_KEY = 'buzz-hide-listened';

function applyListenedFilter(hide) {
  localStorage.setItem(HIDE_LISTENED_KEY, hide ? 'true' : 'false');
  document.querySelectorAll('#episode-list .episode-item.listened').forEach(el => {
    el.style.display = hide ? 'none' : '';
  });
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

  // Restore listened filter state when episode list is shown
  const cb = document.getElementById('hide-listened-cb');
  if (cb) {
    const hide = localStorage.getItem(HIDE_LISTENED_KEY) === 'true';
    cb.checked = hide;
    applyListenedFilter(hide);
  }
});
