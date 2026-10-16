#!/usr/bin/env node
// Run the production isolated-world listener without a browser or dependencies.
// This checks event filtering only; WebKit popup behavior needs Tests/popups.py.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../Sources/Search/PopupGesture.swift'), 'utf8');
const script = source.match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const listeners = new Map();
const sent = [];
vm.runInNewContext(script, {
  window: { webkit: { messageHandlers: { officePopupGesture: { postMessage: kind => sent.push(kind) } } } },
  addEventListener(type, callback, capture) {
    assert.equal(capture, true);
    listeners.set(type, callback);
  },
});
function event(type, fields = {}) {
  listeners.get(type)({ type, isTrusted: true, ...fields });
}
assert.equal(listeners.size, 6);
for (const type of listeners.keys()) event(type, { isTrusted: false, key: 'Enter' });
assert.deepEqual(sent, []);
event('keydown', { key: 'Enter', repeat: false });
assert.deepEqual(sent, ['input']);
for (let i = 0; i < 20; i++) {
  event('keydown', { key: 'Enter', repeat: true });
  event('click', { detail: 0 });
}
assert.deepEqual(sent, ['input']);
for (const key of ['Escape', 'Shift', 'Control', 'Alt', 'Meta']) event('keydown', { key, repeat: false });
assert.deepEqual(sent, ['input']);
event('keyup', { key: 'Enter' });
event('mousedown');
event('click', { detail: 0 });
event('contextmenu');
assert.deepEqual(sent, ['input', 'input', 'click', 'menu']);
event('keydown', { key: ' ', repeat: false });
assert.equal(sent.at(-1), 'input');
console.log('Popup gesture listener: trusted input accepted; synthetic, repeated and modifier keys refused.');
