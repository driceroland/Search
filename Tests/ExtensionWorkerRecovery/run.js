const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const source = process.argv[2] ? fs.readFileSync(process.argv[2], 'utf8') : fs.readFileSync(path.join(__dirname, '../../Sources/Search/ExtensionShims.swift'), 'utf8');
const script = source.split('nonisolated static let script = #"""\n')[1].split('\n    """#')[0];
const harness = fs.readFileSync(path.join(__dirname, 'shim-harness.js'), 'utf8');
const fixture = vm.runInNewContext(harness + '\nrecoveryFixture', { console });
const drain = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };
function load(content, generation = 0, alter = () => {}) {
  const state = fixture(content, generation);
  alter(state);
  vm.runInNewContext(script.replaceAll('__SEARCH_WORKER_GENERATION__', String(generation)), state.root);
  return state;
}
let passed = 0;
async function test(name, run) { await run(); console.log('PASS ' + name); passed++; }
(async () => {
  for (const content of [true, false]) {
    const kind = content ? 'content-script' : 'extension-page';
    await test(kind + ': restart, duplicate notification, no replay/reconnect', async () => {
      const state = load(content), port = state.runtime.connect({ name: 'fixture' });
      let disconnected = 0;
      port.onDisconnect.addListener(() => disconnected++);
      port.postMessage({ question: 'hello' });
      await drain();
      assert.equal(disconnected, 0);
      // With current upstream main the notification has no subscriber and
      // the old port stays open: this assertion reproduces the real entry gap.
      state.subscriptions.forEach(s => s.resolve(1));
      await drain();
      assert.equal(disconnected, 1, kind + ' missed confirmed restart');
      port.nativeDisconnect.fire(port);
      assert.equal(disconnected, 1);
      assert.throws(() => port.postMessage({}), /disconnected port/);
      assert.equal(state.nativePorts.length, 1);
      assert.equal(port.posts.length, 1);
    });
    await test(kind + ': passive subscription, multiple ports, cancellation, native errors', async () => {
      const state = load(content), first = state.runtime.connect(), second = state.runtime.connect();
      let firstCount = 0, secondCount = 0, nativeError;
      first.onDisconnect.addListener(() => { firstCount++; nativeError = state.runtime.lastError; });
      second.onDisconnect.addListener(() => secondCount++);
      await drain();
      assert.equal(state.subscriptions.length, 2, 'each port has a passive lifetime subscription');
      const timers = state.timers.length;
      first.postMessage('one'); second.postMessage('two');
      await drain();
      assert.equal(state.timers.length, timers, 'port messages add no probing timer');
      second.disconnect(); second.disconnect();
      assert.equal(secondCount, 0, 'caller disconnect is silent');
      assert.equal(second.disconnects, 1);
      state.runtime.lastError = { message: 'native failure' };
      first.nativeDisconnect.fire(first);
      delete state.runtime.lastError;
      assert.equal(nativeError.message, 'native failure');
      state.subscriptions[0].resolve(1);
      await drain();
      assert.equal(firstCount, 1); assert.equal(secondCount, 0);
    });
    await test(kind + ': reentrant fresh connection survives, repeated restarts', async () => {
      const state = load(content), old = state.runtime.connect();
      let fresh, oldCount = 0, freshCount = 0;
      old.onDisconnect.addListener(() => {
        oldCount++;
        fresh = state.runtime.connect();
        fresh.onDisconnect.addListener(() => freshCount++);
      });
      state.subscriptions[0].resolve(1);
      await drain();
      assert.equal(oldCount, 1); assert.equal(freshCount, 0);
      assert.equal(state.subscriptions[1].expected, 1);
      fresh.postMessage({ question: 'fresh' });
      let response;
      fresh.onMessage.addListener(message => { response = message; });
      fresh.onMessage.fire({ answer: 'fresh answer' });
      // Numbering wrapper on the own-page port still delivers plain replies.
      assert.equal(response.answer, 'fresh answer');
      state.subscriptions[1].resolve(2);
      await drain();
      assert.equal(oldCount, 1); assert.equal(freshCount, 1);
    });
    await test(kind + ': no restart evidence means no disconnect', async () => {
      for (const outcome of ['pending', 'cancelled', 'rejected']) {
        const state = load(content), port = state.runtime.connect();
        let count = 0;
        port.onDisconnect.addListener(() => count++);
        if (outcome === 'cancelled') state.subscriptions[0].resolve(null);
        if (outcome === 'rejected') state.subscriptions[0].reject(new Error('closed page'));
        await drain();
        assert.equal(count, 0, outcome);
      }
    });
    await test(kind + ': incoming port listeners are preserved and tracked once', async () => {
      const state = load(content), port = state.makePort(); let count = 0, received = 0;
      const listen = given => { received++; given.onDisconnect.addListener(() => count++); };
      state.runtime.onConnect.addListener(listen);
      assert.equal(state.runtime.onConnect.hasListener(listen), true);
      state.runtime.onConnect.fire(port);
      assert.equal(received, 1);
      assert.equal(state.subscriptions.length, 1);
      state.subscriptions[0].resolve(1); await drain();
      assert.equal(count, 1);
      state.runtime.onConnect.removeListener(listen);
      assert.equal(state.runtime.onConnect.hasListener(listen), false);
      state.runtime.onConnect.fire(state.makePort()); assert.equal(received, 1);
    });
    await test(kind + ': BFCache preserves subscription and page exit cancels', async () => {
      const state = load(content); state.runtime.connect();
      const leave = persisted => state.handlers.pagehide.forEach(f => f({ persisted }));
      leave(true); await drain();
      assert.equal(state.calls.includes('background.unobserve'), false);
      state.subscriptions[0].resolve(1); await drain();
      state.runtime.connect(); leave(false); await drain();
      if (!content) assert.equal(state.calls.includes('background.unobserve'), true);
    });
    await test(kind + ': throwing connect creates no subscription', async () => {
      const failure = new Error('native connect refused');
      const state = load(content, 0, state => { state.runtime.connect = () => { throw failure; }; });
      assert.throws(() => state.runtime.connect(), error => error === failure);
      assert.equal(state.subscriptions.length, 0);
      assert.equal(state.nativePorts.length, 0);
    });
    await test(kind + ': external ports untouched', async () => {
      const state = load(content), port = state.runtime.connect('other-extension', { name: 'external' });
      assert.equal(port.onDisconnect, port.nativeDisconnect);
      port.postMessage({ plain: true });
      assert.equal(port.posts[0].plain, true);
      assert.equal(state.subscriptions.length, 0);
    });
  }
  await test('delayed worker-only event is not lost behind a newer context event', async () => {
    for (const content of [true, false]) {
      const state = load(content), older = state.runtime.connect(), newer = state.runtime.connect();
      let oldCount = 0, newCount = 0;
      older.onDisconnect.addListener(() => oldCount++);
      newer.onDisconnect.addListener(() => newCount++);
      state.subscriptions[1].resolve(1); await drain();
      state.subscriptions[0].resolve(0); await drain();
      assert.equal(newCount, 1); assert.equal(oldCount, 1);
    }
  });
  await test('same-context worker replacement retires only native-selected old port', async () => {
    for (const content of [true, false]) {
      const state = load(content), old = state.runtime.connect(), fresh = state.runtime.connect();
      let oldCount = 0, freshCount = 0;
      old.onDisconnect.addListener(() => oldCount++);
      fresh.onDisconnect.addListener(() => freshCount++);
      // Swift binds each subscription to its actual background. The new
      // connection waiting for the replacement is deliberately not resolved.
      state.subscriptions[0].resolve(0); await drain();
      assert.equal(oldCount, 1); assert.equal(freshCount, 0);
      fresh.postMessage({ usable: true });
    }
  });
  await test('slow worker startup has no synthetic disconnect or port deadline', async () => {
    let answerPing;
    const state = load(false, 0, state => {
      Object.getPrototypeOf(state.runtime).sendMessage = () => new Promise(resolve => { answerPing = resolve; });
    });
    const port = state.runtime.connect(); let count = 0;
    port.onDisconnect.addListener(() => count++);
    await drain();
    state.now += 14000;
    assert.equal(count, 0);
    answerPing('pong'); await drain();
    assert.equal(count, 0);
    assert.equal(state.calls.includes('background.revive'), false);
    assert.deepEqual(Array.from(state.timers, t => t.delay), [15000], 'only existing checkWorker timeout');
  });
  await test('native wake and another page use the same generation fanout', async () => {
    for (const cause of ['background.wake', 'another extension page']) {
      const contexts = [load(true), load(false), load(false)];
      const counts = [0, 0, 0];
      contexts.forEach((state, i) => state.runtime.connect().onDisconnect.addListener(() => counts[i]++));
      // Models the shared Swift broadcaster, not a live WebKit restart.
      contexts.forEach(state => state.subscriptions[0].resolve(1));
      await drain(); assert.deepEqual(counts, [1, 1, 1], cause);
    }
  });
  await test('missing isolated bridge fails closed, native disconnect still works', async () => {
    const state = load(true, 0, state => { delete state.root.webkit; });
    const port = state.runtime.connect(); let count = 0;
    port.onDisconnect.addListener(() => count++);
    await drain(); assert.equal(count, 0);
    port.nativeDisconnect.fire(port); assert.equal(count, 1);
  });
  await test('newly loaded shim subscribes to its own generation', async () => {
    for (const content of [true, false]) {
      const state = load(content, 3), port = state.runtime.connect(); let count = 0;
      port.onDisconnect.addListener(() => count++);
      assert.equal(state.subscriptions[0].expected, 3);
      state.subscriptions[0].resolve(null); await drain(); assert.equal(count, 0);
    }
  });
  console.log(passed + ' full-shim regression cases passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
