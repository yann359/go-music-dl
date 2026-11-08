const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function harness() {
  const messages = [];
  const audio = new EventTarget();
  const ap = {
    audio, options: {loop: 'all', order: 'list'},
    list: {
      audios: [], index: 0,
      add(items) { this.audios.push(...items); if (this.audios.length) this.switch(this.index); },
      clear() { this.audios = []; this.index = 0; },
      remove(index) { this.audios.splice(index, 1); },
      switch(index) { this.index = index; audio.src = this.audios[index]?.url || ''; audio.currentTime = 0; }
    },
    setUIPlaying() { this.paused = false; }, setUIPaused() { this.paused = true; },
    notice() {}
  };
  const context = {
    window: {webkit: {messageHandlers: {musicDL: {postMessage: message => messages.push(message)}}}},
    document: {hidden: false, addEventListener() {}}, Event, queueMicrotask,
    playbackEntryFromSong: song => ({...song, custom_id: song.id, url: '/music/download?stream=1'})
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../MusicDL/native-audio.js'), 'utf8'), context);
  context.window.musicDLNative.attach(ap);
  messages.length = 0;
  return {ap, audio, messages, bridge: context.window.musicDLNative};
}
const entry = id => ({custom_id: id, source: 'netease', name: id, artist: 'Fixture', url: '/music/download?stream=1'});
const tick = () => new Promise(resolve => setImmediate(resolve));

test('native queue is sent before play and no real media URL is set', async () => {
  const {ap, audio, messages} = harness();
  ap.list.add([entry('one'), entry('two'), entry('three')]);
  await audio.play(); await tick();
  assert.deepEqual(messages.map(x => x.action), ['queue', 'seek', 'play']);
  assert.equal(messages[0].songs.length, 3);
  assert.equal(messages[0].songs[0].id, 'one');
  assert.equal(typeof Object.getOwnPropertyDescriptor(audio, 'src').set, 'function');
});

test('native advancing and seeking never echo queue/play/seek back to native', async () => {
  const {ap, bridge, messages, audio} = harness();
  ap.list.add([entry('one'), entry('two')]); await tick(); messages.length = 0;
  bridge.receive({index: 1, position: 42, duration: 180, playing: true, rate: 1});
  await tick();
  assert.equal(ap.list.index, 1);
  assert.equal(audio.currentTime, 42);
  assert.equal(audio.paused, false);
  assert.deepEqual(messages, []);
});

test('native owns next/previous and mode changes', async () => {
  const {ap, messages} = harness();
  ap.list.add([entry('one'), entry('two')]); await tick(); messages.length = 0;
  ap.skipForward(); ap.skipBack(); ap.options.loop = 'one'; await tick();
  assert.deepEqual(messages.map(x => x.action), ['next', 'previous', 'queue']);
  assert.equal(messages[2].loop, 'one');
});

test('queue clear is propagated and paused state cancels a pending play', async () => {
  const {ap, audio, messages} = harness();
  ap.list.add([entry('one')]); await tick(); messages.length = 0;
  audio.play(); audio.pause(); ap.list.clear(); await tick();
  assert.equal(messages.some(x => x.action === 'play'), false);
  assert.equal(messages.find(x => x.action === 'queue').songs.length, 0);
});

test('new WebView restores native queue without replaying or resetting progress', async () => {
  const {ap, bridge, messages, audio} = harness();
  bridge.receive({index: 1, position: 77, duration: 180, playing: true, rate: 1,
    songs: [{id: 'one'}, {id: 'two'}], loop: 'all', order: 'list'});
  await tick();
  assert.equal(ap.list.audios.length, 2);
  assert.equal(ap.list.index, 1);
  assert.equal(audio.currentTime, 77);
  assert.deepEqual(messages, []);
});

test('buffering remains pausable in APlayer controls', async () => {
  const {ap, bridge, audio, messages} = harness();
  ap.list.add([entry('one')]); await tick(); messages.length = 0;
  bridge.receive({index: 0, position: 0, duration: 0, playing: false, waiting: true, rate: 1});
  assert.equal(audio.paused, false);
  assert.equal(ap.paused, false);
  audio.pause();
  assert.equal(messages[0].action, 'pause');
});
