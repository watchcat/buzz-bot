import { signal, computed, effect } from '@preact/signals';

// ── Signals — source of truth for all player state ───────────────────────────
export const currentEpisode = signal(null);
// shape: { id, src, title, artist, artwork, start, autoplay, subscribed }

export const isPlaying     = signal(false);
export const currentTime   = signal(0);
export const duration      = signal(0);
export const playbackRate  = signal(parseFloat(localStorage.getItem('buzz-playback-speed') || '1'));
export const cacheProgress = signal(0); // 0..1, drives the green cache layer on the seek bar

// ── Audio element ─────────────────────────────────────────────────────────────
// Owned here; appended to <body> so MediaSession and autoplay policies work.
export const audio = new Audio();
audio.preload = 'metadata';
document.body.appendChild(audio);

// ── Internal state ────────────────────────────────────────────────────────────
let playIntent    = false; // true = user wants audio playing; survives system pauses
let progressTimer = null;
let audioBlobUrl  = null;

const SPEEDS = [1, 1.5, 2];
const LAST_EPISODE_KEY      = 'buzz-last-episode-id';
const LAST_EPISODE_META_KEY = 'buzz-last-episode-meta';
const SPEED_KEY             = 'buzz-playback-speed';

// ── Commands ──────────────────────────────────────────────────────────────────

export async function load(data) {
  const newId = String(data.episodeId ?? data['episode-id']);
  if (audio.dataset.episodeId === newId) return;

  playIntent = false;
  if (progressTimer) { clearTimeout(progressTimer); progressTimer = null; }
  if (audioBlobUrl)  { URL.revokeObjectURL(audioBlobUrl); audioBlobUrl = null; }

  audio.dataset.episodeId = newId;

  const ep = {
    id:         newId,
    src:        data.src        || '',
    title:      data.title      || '',
    artist:     data.artist     || '',
    artwork:    data.artwork     || '',
    start:      parseInt(data.start || '0', 10),
    autoplay:   data.autoplay   === '1',
    subscribed: data.subscribed === '1',
  };
  currentEpisode.value = ep;

  localStorage.setItem(LAST_EPISODE_KEY, newId);
  localStorage.setItem(LAST_EPISODE_META_KEY, JSON.stringify({
    title: ep.title, podcast: ep.artist, artwork: ep.artwork,
  }));

  // Prefer cached blob, fall back to CDN stream
  const cachedUrl = await window.getCachedBlobUrl?.(newId).catch(() => null);
  if (cachedUrl) {
    audioBlobUrl       = cachedUrl;
    audio.src          = cachedUrl;
    cacheProgress.value = 1;
  } else {
    audio.src          = ep.src.replace(/^http:\/\//i, 'https://');
    cacheProgress.value = window.isCachedSync?.(newId) ? 1 : 0;
  }

  audio.load();
  audio.addEventListener('loadedmetadata', () => {
    if (ep.start > 0) audio.currentTime = ep.start;
    audio.playbackRate = playbackRate.value;
    if (ep.autoplay) audio.play().catch(() => {});
  }, { once: true });

  _setupMediaSession(ep);
  _startAutoCaching(newId);
}

export function togglePlay() {
  if (audio.paused) audio.play().catch(() => {});
  else userPause();
}

export function userPause() {
  playIntent = false;
  audio.pause();
}

export function seek(time) {
  audio.currentTime = Math.max(0, Math.min(audio.duration || 0, time));
  _syncPositionState();
}

export function seekRelative(delta) {
  seek(audio.currentTime + delta);
}

export function setRate(rate) {
  const ep = currentEpisode.value;
  if (rate !== 1 && !ep?.subscribed) {
    window.showSubscribePrompt?.();
    return;
  }
  audio.playbackRate = rate;
  playbackRate.value = rate;
  localStorage.setItem(SPEED_KEY, String(rate));
  _syncPositionState();
}

export function cycleSpeed() {
  const idx  = SPEEDS.indexOf(playbackRate.value);
  const next = SPEEDS[(idx + 1) % SPEEDS.length];
  setRate(next);
}

export function getInitData() {
  return window.Telegram?.WebApp?.initData
    || document.getElementById('initData')?.value || '';
}

// ── Audio event listeners ─────────────────────────────────────────────────────

audio.addEventListener('play', () => {
  playIntent = true;
  isPlaying.value = true;
  _ensureAudioContext();
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
  _syncPositionState();
});

audio.addEventListener('pause', () => {
  isPlaying.value = false;
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
  _flushProgress();
});

audio.addEventListener('ended', () => {
  playIntent = false;
  isPlaying.value = false;
  _flushProgress(true);
});

audio.addEventListener('timeupdate', () => {
  currentTime.value = audio.currentTime;
  if (progressTimer) return;
  progressTimer = setTimeout(() => {
    progressTimer = null;
    const id = audio.dataset.episodeId;
    if (!id) return;
    _saveProgress(id, Math.floor(audio.currentTime),
      audio.duration > 0 && (audio.duration - audio.currentTime) < 30);
  }, 5000);
});

audio.addEventListener('durationchange', () => {
  duration.value = isFinite(audio.duration) ? audio.duration : 0;
  _syncPositionState();
});

audio.addEventListener('loadedmetadata', () => {
  duration.value = isFinite(audio.duration) ? audio.duration : 0;
});

document.addEventListener('visibilitychange', () => {
  if (!document.hidden) {
    if (_audioCtx?.state === 'suspended') _audioCtx.resume();
    if (playIntent && audio.paused) {
      setTimeout(() => { if (playIntent && audio.paused) audio.play().catch(() => {}); }, 250);
    }
  }
});

// Hardware media keys (Android WebView doesn't expose MediaSession action handlers)
function _handleMediaKey(e) {
  const isPlayPause = e.key === 'MediaPlayPause' || e.keyCode === 179;
  const isPlay      = e.key === 'MediaPlay'      || e.keyCode === 175;
  const isPause     = e.key === 'MediaPause'     || e.keyCode === 19;
  const isStop      = e.key === 'MediaStop'      || e.keyCode === 178;
  if (isPlayPause || isPlay || isPause || isStop) {
    e.preventDefault();
    if (isPlayPause)      togglePlay();
    else if (isPlay)  { if (audio.paused) audio.play().catch(() => {}); }
    else              { if (!audio.paused) userPause(); }
  }
}
document.addEventListener('keydown', _handleMediaKey);
document.addEventListener('keyup',   _handleMediaKey);

// ── Caching integration ───────────────────────────────────────────────────────

function _startAutoCaching(episodeId) {
  if (!window.isCachedSync || window.isCachedSync(episodeId)) return;
  if (!window.downloadAndCache) return;

  window.downloadAndCache(episodeId, getInitData(), pct => {
    if (audio.dataset.episodeId !== String(episodeId)) return;
    cacheProgress.value = pct ?? 0;
  }).then(() => {
    if (audio.dataset.episodeId !== String(episodeId)) return;
    cacheProgress.value = 1;
    // Switch live stream → cached blob (no network needed for seeking)
    window.getCachedBlobUrl?.(episodeId).then(blobUrl => {
      if (!blobUrl || audio.dataset.episodeId !== String(episodeId)) return;
      const wasPlaying = !audio.paused;
      const savedTime  = audio.currentTime;
      if (audioBlobUrl) URL.revokeObjectURL(audioBlobUrl);
      audioBlobUrl = blobUrl;
      audio.src = blobUrl;
      audio.load();
      audio.addEventListener('loadedmetadata', () => {
        if (audio.dataset.episodeId !== String(episodeId)) return;
        audio.currentTime = savedTime;
        if (wasPlaying) audio.play().catch(() => {});
      }, { once: true });
    });
  }).catch(() => {
    cacheProgress.value = 0;
  });
}

// ── Progress persistence ──────────────────────────────────────────────────────

function _flushProgress(completed = false) {
  if (progressTimer) { clearTimeout(progressTimer); progressTimer = null; }
  const id = audio.dataset.episodeId;
  if (!id) return;
  _saveProgress(id, Math.floor(audio.currentTime), completed);
}

function _saveProgress(episodeId, seconds, completed) {
  const url  = `/episodes/${episodeId}/progress`;
  const opts = {
    method:  'PUT',
    headers: { 'Content-Type': 'application/json', 'X-Init-Data': getInitData() },
    body:    JSON.stringify({ seconds, completed }),
  };
  // Use write queue when available (added in a later PR); fall back to plain fetch
  (window.queuedFetch ?? fetch)(url, opts).catch(() => {});
}

// ── MediaSession + AudioContext ───────────────────────────────────────────────

function _setupMediaSession(ep) {
  if (!('mediaSession' in navigator)) return;
  navigator.mediaSession.metadata = new MediaMetadata({
    title:   ep.title,
    artist:  ep.artist,
    artwork: ep.artwork ? [{ src: ep.artwork, sizes: '512x512', type: 'image/jpeg' }] : [],
  });
  navigator.mediaSession.setActionHandler('play',         () => audio.play().catch(() => {}));
  navigator.mediaSession.setActionHandler('pause',        () => userPause());
  navigator.mediaSession.setActionHandler('stop',         () => userPause());
  navigator.mediaSession.setActionHandler('seekbackward', d  => seekRelative(-(d.seekOffset ?? 10)));
  navigator.mediaSession.setActionHandler('seekforward',  d  => seekRelative(+(d.seekOffset ?? 30)));
  navigator.mediaSession.setActionHandler('seekto',       d  => seek(d.seekTime));
}

function _syncPositionState() {
  if (!('mediaSession' in navigator) || !navigator.mediaSession.setPositionState) return;
  if (!audio.duration || !isFinite(audio.duration)) return;
  navigator.mediaSession.setPositionState({
    duration:     audio.duration,
    playbackRate: audio.playbackRate,
    position:     Math.min(audio.currentTime, audio.duration),
  });
}

let _audioCtx = null;
function _ensureAudioContext() {
  if (!_audioCtx) _audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  if (_audioCtx.state === 'suspended') _audioCtx.resume();
}

// ── Session restore ───────────────────────────────────────────────────────────
// Re-populate currentEpisode from localStorage so MiniPlayer is visible
// immediately on page load (audio is not loaded yet — tapping navigates to player).
(function _restoreSession() {
  const savedId = localStorage.getItem(LAST_EPISODE_KEY);
  if (!savedId) return;
  try {
    const meta = JSON.parse(localStorage.getItem(LAST_EPISODE_META_KEY) || '{}');
    currentEpisode.value = {
      id:         savedId,
      src:        '',        // empty — load() called when user taps or HTMX navigates
      title:      meta.title   || '',
      artist:     meta.podcast || '',
      artwork:    meta.artwork  || '',
      start:      0,
      autoplay:   false,
      subscribed: false,
    };
  } catch { /* ignore corrupt localStorage */ }
}());
