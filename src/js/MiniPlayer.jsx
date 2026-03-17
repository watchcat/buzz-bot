import { currentEpisode, isPlaying, playbackRate, togglePlay, cycleSpeed } from './player-bus.js';

export function MiniPlayer() {
  const ep      = currentEpisode.value;
  const playing = isPlaying.value;
  const rate    = playbackRate.value;

  if (!ep) return null;

  const speedLabel  = rate === 1 ? '1×' : `${rate}×`;
  const speedActive = rate !== 1;

  function handleBarClick() {
    // Navigate to full player page via HTMX
    htmx.ajax('GET', `/episodes/${ep.id}/player`, { target: '#content', swap: 'innerHTML' });
  }

  return (
    <div class="now-playing-bar">
      <div class="now-playing-inner" onClick={handleBarClick}>
        <div class="now-playing-artwork"
             style={ep.artwork ? { backgroundImage: `url('${ep.artwork}')` } : {}}>
          {!ep.artwork && '🎙'}
        </div>
        <div class="now-playing-text">
          <span class="now-playing-title">{ep.title}</span>
          <span class="now-playing-podcast">{ep.artist}</span>
        </div>
      </div>
      <button class={`btn-speed${speedActive ? ' btn-speed--active' : ''}`}
              onClick={cycleSpeed}>{speedLabel}</button>
      <button class="now-playing-playpause" onClick={togglePlay}>
        {playing ? '⏸' : '▶'}
      </button>
    </div>
  );
}
