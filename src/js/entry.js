// PR 1 entry point — exposes playerBus globally, no rendering yet.
// PR 2 will replace this with MiniPlayer.jsx (Preact component).
import * as playerBus from './player-bus.js';
window.playerBus = playerBus;
