// Checks the fixture's observation mechanics with VM objects. These are not
// native WebKit recovery results; live.py remains the actual lifecycle test.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const contentSource = fs.readFileSync(path.join(__dirname, 'extension/content.js'), 'utf8');
const workerSource = fs.readFileSync(path.join(__dirname, 'extension/worker.js'), 'utf8');
const siteSource = fs.readFileSync(path.join(__dirname, 'site.html'), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
let passed = 0;
const test = (name, run) => { run(); console.log('PASS fixture: ' + name); passed++; };
const plain = value => JSON.parse(JSON.stringify(value));
const event = () => {
  const listeners = [];
  return { listeners, addListener: listener => listeners.push(listener),
    emit: (...args) => { for (const listener of [...listeners]) listener(...args); } };
};
function documentFixture() {
  const attributes = new Map(), listeners = new Map(), payloads = [];
  const document = {
    documentElement: {
      getAttribute: name => attributes.has(name) ? attributes.get(name) : null,
      hasAttribute: name => attributes.has(name),
      setAttribute: (name, value) => attributes.set(name, String(value)),
    },
    addEventListener(name, listener) {
      if (!listeners.has(name)) listeners.set(name, []);
      listeners.get(name).push(listener);
    },
    dispatchEvent(value) {
      if (value.type === 'search-port-fixture-report') payloads.push(value.detail);
      for (const listener of [...(listeners.get(value.type) || [])]) listener(value);
    },
  };
  const page = vm.createContext({ document, performance: { timeOrigin: 12345 } });
  vm.runInContext(siteSource, page);
  return { document, page, listeners, payloads,
    audit: () => plain(page.__searchPortDocumentFixture),
    state: () => JSON.parse(attributes.get('data-search-port-fixture')) };
}
function contentWorld(fixture, ports) {
  const runtime = { connect() {
    const port = { onDisconnect: event(), onMessage: event(), posted: [],
      postMessage(message) { this.posted.push(plain(message)); } };
    ports.push(port);
    return port;
  } };
  return vm.createContext({ document: fixture.document, chrome: { runtime },
    CustomEvent: class { constructor(type, options) { this.type = type; this.detail = options.detail; } } });
}
const inject = world => vm.runInContext(contentSource, world);
const click = (fixture, id, token) => fixture.document.dispatchEvent({ type: 'click', target: { id, dataset: { token } } });

(async () => {
  const fixture = documentFixture(), ports = [], world = contentWorld(fixture, ports);
  const documentID = fixture.audit().document;
  inject(world);
  const originalInstance = fixture.state().instance;
  test('initial document nonce precedes the single initial connect', () => {
    assert.equal(fixture.state().document, documentID);
    assert.equal(ports.length, 1);
    assert.equal(fixture.listeners.get('click').length, 1);
    assert.equal(fixture.audit().events[0].reason, 'boot');
  });
  ports[0].onMessage.emit({ echo: { token: 'initial-content' }, worker: 'worker-a' });
  test('same-world reinjection preserves actual held port and listeners', () => {
    inject(world); inject(world);
    assert.equal(ports.length, 1);
    assert.equal(fixture.listeners.get('click').length, 1);
    assert.equal(fixture.state().instance, originalInstance);
    assert.equal(fixture.state().reinjections, 2);
    assert.equal(fixture.state().replies, 1);
    assert.equal(world.__searchPortRecoveryFixtureV1.held[0], ports[0]);
    assert.equal(fixture.audit().counts.reinjection, 2);
  });
  test('DOM or page audit data never reconstructs isolated port counters', () => {
    fixture.document.documentElement.setAttribute('data-search-port-fixture', '{"opened":999}');
    fixture.page.__searchPortDocumentFixture.instances[originalInstance].opened = 888;
    inject(world);
    assert.equal(fixture.state().opened, 1);
    assert.equal(fixture.audit().instances[originalInstance].opened, 1);
  });
  test('original callback is observable after reinjection without reconnect', () => {
    ports[0].onDisconnect.emit();
    assert.equal(fixture.state().ports[0].disconnected, 1);
    assert.equal(fixture.audit().counts.disconnect, 1);
    assert.equal(ports.length, 1);
  });
  test('duplicate callbacks are counted, never hidden by the fixture', () => {
    ports[0].onDisconnect.emit();
    assert.equal(fixture.state().ports[0].disconnected, 2);
    assert.equal(fixture.audit().counts.disconnect, 2);
  });
  test('each explicit click opens one fresh port after multiple injections', () => {
    click(fixture, 'connect-content', 'fresh-1');
    assert.equal(ports.length, 2);
    assert.equal(fixture.state().opened, 2);
    assert.equal(fixture.state().ports[0].disconnected, 2);
    assert.equal(fixture.state().ports[1].disconnected, 0);
    assert.equal(ports[1].posted[0].token, 'fresh-1');
  });
  test('fresh isolated world on the same document fails without connecting', () => {
    const oldHistory = fixture.audit().instances[originalInstance];
    const replacement = contentWorld(fixture, ports);
    inject(replacement);
    assert.equal(fixture.state().worldReplaced, true);
    assert.equal(fixture.state().opened, 0);
    assert.equal(fixture.state().errors.length, 1);
    assert.notEqual(fixture.state().instance, originalInstance);
    assert.equal(ports.length, 2);
    assert.equal(fixture.listeners.get('click').length, 1);
    assert.equal(fixture.audit().document, documentID);
    assert.deepEqual(fixture.audit().instances[originalInstance], oldHistory);
    assert.equal(fixture.audit().counts['world-replaced'], 1);
    assert.equal(Object.keys(fixture.audit().instances).length, 2);
  });
  test('serialized observations expose no isolated fixture closures or ports', () => {
    assert.equal(fixture.page.__searchPortRecoveryFixtureV1, undefined);
    for (const payload of fixture.payloads) {
      assert.equal(typeof payload, 'string');
      const record = JSON.parse(payload);
      assert.equal(record.state.kind, 'content');
      assert.equal(record.held, undefined);
      assert.equal(record.state.held, undefined);
      assert.equal(record.state.ports.some(port => port.postMessage !== undefined), false);
    }
  });
  test('a truly new document gets its own identity and initial port', () => {
    const next = documentFixture();
    inject(contentWorld(next, ports));
    assert.notEqual(next.audit().document, documentID);
    assert.equal(next.state().worldReplaced, false);
    assert.equal(next.state().opened, 1);
    assert.equal(ports.length, 3);
  });
  test('audit event history is bounded while preserving earliest observations', () => {
    for (let n = 0; n < 300; n++) inject(world);
    const audit = fixture.audit();
    assert.equal(audit.events.length, 256);
    assert.ok(audit.omittedEvents > 0);
    assert.equal(audit.events[0].reason, 'boot');
    assert.equal(audit.document, documentID);
    assert.equal(ports.length, 3);
  });
  for (const [registrationFailure, deliveryFailure] of [[false, false], [false, true], [true, false]]) {
    const order = [], reports = [], errors = [], echoes = [];
    let onConnect;
    const runtime = {
      onConnect: { addListener(listener) {
        order.push('connect');
        if (registrationFailure) throw new Error('registration failed');
        onConnect = listener;
      } },
      onMessage: { addListener() { order.push('message'); } },
      sendNativeMessage(host, payload) {
        assert.equal(host, 'search'); assert.equal(payload.api, 'debug.error');
        const [phase, nonce] = payload.args[0].split(':');
        assert.match(nonce, /^[0-9]+-[a-z0-9]+$/);
        if (phase === 'fixture-worker-ready') assert.deepEqual(order, ['connect', 'message']);
        reports.push({ phase, nonce });
        return Promise.resolve(deliveryFailure ? { error: 'delivery failed' } : { value: null });
      },
    };
    try {
      vm.runInNewContext(workerSource, { chrome: { runtime }, console: { error: value => errors.push(value) }, setTimeout, performance });
      assert.equal(registrationFailure, false);
    } catch (error) { assert.equal(registrationFailure, true); assert.match(String(error), /registration failed/); }
    for (let n = 0; n < 10; n++) await Promise.resolve();
    test(`worker registration diagnostics (registrationFailure=${registrationFailure}, deliveryFailure=${deliveryFailure})`, () => {
      assert.deepEqual(reports.map(item => item.phase), registrationFailure ? ['fixture-worker-entry'] : ['fixture-worker-entry', 'fixture-worker-ready']);
      if (!registrationFailure) {
        let receive;
        onConnect({ onMessage: { addListener(listener) { receive = listener; } }, postMessage(message) { echoes.push(message); } });
        receive({ from: 'fixture-check' });
        assert.equal(echoes[0].worker, reports[1].nonce);
      }
      assert.equal(errors.length, deliveryFailure ? 2 : 0);
    });
  }
  console.log(`${passed} fixture observation checks passed (VM; not live WebKit)`);
})().catch(error => { console.error(error); process.exitCode = 1; });
