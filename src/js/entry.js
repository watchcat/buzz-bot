import { render } from 'preact';
import { effect } from '@preact/signals';
import * as playerBus from './player-bus.js';
import { MiniPlayer } from './MiniPlayer.jsx';

// Expose globally: app.js uses playerBus.*, player.ecr onclick handlers use
// window-scoped shims (togglePlayPause etc.) defined in app.js.
window.playerBus = { ...playerBus, effect };

// Mount the persistent mini-player bar
const root = document.getElementById('miniplayer-root');
if (root) render(<MiniPlayer />, root);
