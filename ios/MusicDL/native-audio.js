/* Phase 1: APlayer renders the existing controls; AVQueuePlayer owns audio.
 * Injected at document start by the trusted iOS host, never served to browsers.
 */
(() => {
  "use strict";
  const post = payload => window.webkit.messageHandlers.musicDL.postMessage(payload);
  let applying = false;
  let player;
  let audio;
  let latest = {index: 0, position: 0, duration: 0, playing: false, rate: 1};
  let pendingQueue = false;
  let pendingPlay = false;
  let pendingSeek;
  let lastQueue = "";
  let reportedMessage = "";

  function snapshot() {
    const songs = (player.list.audios || []).map(item => ({
      id: String(item.custom_id || ""), source: String(item.source || ""),
      name: String(item.name || ""), artist: String(item.artist || ""),
      album: String(item.album || ""), cover: String(item.cover || ""),
      duration: Math.max(0, Math.trunc(Number(item.duration) || 0)),
      extra: typeof item.extra === "string" ? item.extra : JSON.stringify(item.extra || {})
    }));
    return {action: "queue", songs, index: Math.max(0, player.list.index || 0),
      loop: player.options.loop, order: player.options.order};
  }

  function flush() {
    pendingQueue = false;
    if (applying || !player) return;
    const queue = snapshot();
    const encoded = JSON.stringify(queue);
    if (encoded !== lastQueue) { lastQueue = encoded; post(queue); }
    if (pendingSeek !== undefined) { post({action: "seek", value: pendingSeek}); pendingSeek = undefined; }
    if (pendingPlay) { pendingPlay = false; post({action: "play"}); }
  }

  function schedule() {
    if (applying || pendingQueue) return;
    pendingQueue = true;
    queueMicrotask(flush);
  }

  function event(name) { audio.dispatchEvent(new Event(name)); }

  window.musicDLNative = {
    attach(ap) {
      if (player || !ap?.audio) return;
      player = ap; audio = ap.audio;
      // This element never gets a media URL. It remains an event adapter for
      // APlayer/lyrics/AI controls; all getters mirror authoritative native state.
      let src = "";
      Object.defineProperties(audio, {
        src: {configurable: true, get: () => src, set: value => { src = String(value); schedule(); }},
        currentSrc: {configurable: true, get: () => src},
        currentTime: {configurable: true, get: () => latest.position, set: value => {
          if (!applying && Number.isFinite(Number(value))) { pendingSeek = Number(value); schedule(); }
        }},
        duration: {configurable: true, get: () => latest.duration},
        paused: {configurable: true, get: () => !latest.playing && !latest.waiting},
        ended: {configurable: true, get: () => false},
        readyState: {configurable: true, get: () => latest.duration > 0 ? 4 : 0},
        buffered: {configurable: true, get: () => ({length: latest.duration > 0 ? 1 : 0,
          start: () => 0, end: () => latest.duration})},
        playbackRate: {configurable: true, get: () => latest.rate, set: value => {
          if (!applying && Number.isFinite(Number(value))) post({action: "rate", value: Number(value)});
        }},
        volume: {configurable: true, get: () => ap.__nativeVolume ?? 0.7, set: value => {
          ap.__nativeVolume = Number(value);
          if (!applying) post({action: "volume", value: Number(value)});
        }}
      });
      audio.play = () => { if (!applying) { pendingPlay = true; schedule(); } return Promise.resolve(); };
      audio.pause = () => { if (!applying) { pendingPlay = false; post({action: "pause"}); } };
      audio.load = () => { if (!applying) schedule(); };
      for (const name of ["add", "remove", "clear", "switch"]) {
        const original = ap.list[name].bind(ap.list);
        ap.list[name] = (...args) => {
          const result = original(...args);
          if (!applying) schedule();
          return result;
        };
      }
      // Native owns queue advancement, including single/random/list looping.
      ap.skipForward = () => { if (!applying) post({action: "next"}); };
      ap.skipBack = () => { if (!applying) post({action: "previous"}); };
      // Mode controls mutate these properties directly.
      for (const property of ["loop", "order"]) {
        let value = ap.options[property];
        Object.defineProperty(ap.options, property, {configurable: true, get: () => value,
          set: next => { value = next; schedule(); }});
      }
      post({action: "state"});
    },
    receive(state) {
      if (!player) return;
      applying = true;
      try {
        const wasPlaying = latest.playing;
        // A WebContent process may be recreated while native audio continues.
        // Rehydrate its visual queue from native state without restarting audio.
        if (!player.list.audios.length && state.songs?.length &&
            typeof playbackEntryFromSong === "function") {
          player.list.add(state.songs.map(playbackEntryFromSong));
          player.options.loop = state.loop;
          player.options.order = state.order;
        }
        const changedTrack = state.index !== player.list.index;
        latest = state;
        if (changedTrack && player.list.audios[state.index]) player.list.switch(state.index);
        // A state-driven list.switch must never echo a seek-to-zero or a queue reset.
        lastQueue = JSON.stringify(snapshot());
        if (state.playing || state.waiting) player.setUIPlaying(); else player.setUIPaused();
        if (changedTrack) event("loadedmetadata");
        event("durationchange"); event("timeupdate"); event("progress");
        if (state.playing !== wasPlaying) {
          if (state.playing) { event("play"); event("playing"); }
          else event("pause");
        }
        if (state.message !== reportedMessage) {
          reportedMessage = state.message;
          if (/失败|不可播放/.test(state.message || "")) player.notice(state.message, 6000);
        }
      } finally { applying = false; }
    }
  };
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) post({action: "state"});
  });
})();
