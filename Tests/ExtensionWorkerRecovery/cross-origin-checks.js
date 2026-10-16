const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const scripts = name => [...fs.readFileSync(path.join(__dirname, name), 'utf8').matchAll(/<script>([\s\S]*?)<\/script>/g)].map(match => match[1]);
const listeners = {}, buttons = {}, attributes = new Map(), sent = [];
const childWindow = { postMessage: (value, origin) => sent.push({ value, origin }) };
const frame = { contentWindow: childWindow };
for (const id of ['connect-content', 'send-content', 'roundtrip-content']) buttons[id] = { dataset: { token: 'fixture-token' }, addEventListener: (_, callback) => buttons[id].click = callback };
vm.runInNewContext(scripts('cross-origin.html')[0].replaceAll('FIXTURE_PORT', '12345'), {
  location: { origin: 'http://localhost:12345' },
  document: { createElement: () => frame, getElementById: id => buttons[id], body: { appendChild() {} }, documentElement: { setAttribute: (key, value) => attributes.set(key, value) } },
  addEventListener: (name, callback) => listeners[name] = callback,
});
const state = { opened: 1, disconnected: 0 }, audit = { document: 'actual-child', counts: { connect: 1 } };
const report = { kind: 'child-port-observation', state, audit };
listeners.message({ source: {}, origin: 'http://127.0.0.1:12345', data: report });
listeners.message({ source: childWindow, origin: 'http://localhost:12345', data: report });
assert.equal(attributes.size, 0);
listeners.message({ source: childWindow, origin: 'http://127.0.0.1:12345', data: report });
assert.deepEqual(JSON.parse(attributes.get('data-search-port-fixture')), state);
buttons['connect-content'].click();
assert.deepEqual(JSON.parse(JSON.stringify(sent[0])), { value: { kind: 'child-port-command', button: 'connect-content', token: 'fixture-token', scheduledAt: null }, origin: 'http://127.0.0.1:12345' });
const parentWindow = {}, childListeners = {}, clicked = [];
vm.runInNewContext(scripts('site.html')[1], {
  parent: parentWindow, window: {}, location: { port: '12345' },
  document: { addEventListener() {}, getElementById: () => ({ dataset: {}, click: () => clicked.push(true) }) },
  addEventListener: (name, callback) => childListeners[name] = callback,
});
const command = { kind: 'child-port-command', button: 'connect-content', token: 'fixture-token' };
childListeners.message({ source: {}, origin: 'http://localhost:12345', data: command });
childListeners.message({ source: parentWindow, origin: 'http://127.0.0.1:12345', data: command });
assert.equal(clicked.length, 0);
childListeners.message({ source: parentWindow, origin: 'http://localhost:12345', data: command });
assert.equal(clicked.length, 1);
console.log('PASS: parent and child enforce both origin and frame identity; relay preserves observations; explicit fresh-connect command reaches only the child.');
