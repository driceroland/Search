const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../../Sources/Search/ExtensionShims.swift'), 'utf8');
const script = source.split('nonisolated static let script = #"""\n')[1].split('\n    """#')[0];
const harness = fs.readFileSync(path.join(__dirname, '../ExtensionWorkerRecovery/shim-harness.js'), 'utf8');
const fixture = vm.runInNewContext(harness + '\nrecoveryFixture', { console });
const owner = fixture(false), reader = fixture(true), spectator = fixture(false);
const states = [owner, reader, spectator];
const wire = [];
let next = 0, nativeFetches = 0;
for (const state of states) {
  class LocalURL extends URL {
    static createObjectURL() { return 'blob:webkit-extension://fixture/' + (++next); }
    static revokeObjectURL() {}
  }
  Object.assign(state.root, { URL: LocalURL, Blob, Request, Response, ReadableStream, DOMException, Uint8Array, btoa, atob, crypto });
  state.root.fetch = (...args) => { nativeFetches++; return Promise.resolve(new Response('native')); };
  Object.getPrototypeOf(state.runtime).sendMessage = message => new Promise(resolve => {
    wire.push(message);
    for (const receiver of states.filter(s => s !== state)) receiver.runtime.onMessage.fire(message, { id: 'fixture', url: state.root.location.href }, resolve);
  });
  vm.runInNewContext(script, state.root);
}
const evaluate = (state, js) => vm.runInNewContext(js, state.root);
(async () => {
  const size = 8 * 1024 * 1024 + 11;
  const url = evaluate(owner, `URL.createObjectURL(new Blob([Uint8Array.from({length:${size}}, (_, i) => i % 256)], {type:'application/octet-stream'}))`);
  const response = await reader.root.fetch(url);
  assert.equal(response.url, url);
  assert.equal(response.headers.get('content-length'), String(size));
  assert.equal(wire.length, 1, 'body must stay unread until requested');
  const bytes = new Uint8Array(await response.arrayBuffer());
  assert.equal(bytes.length, size);
  assert.ok(bytes.every((x, i) => x === i % 256), 'binary bytes must survive every chunk boundary');
  assert.ok(wire.filter(m => m.__searchBlob.offset !== undefined).length > 1);
  assert.equal(nativeFetches, 0, 'cross-world blob read must not hit native CORS');
  await reader.root.fetch('https://example.test/');
  assert.equal(nativeFetches, 1, 'ordinary fetch must pass through');
  const signal = new AbortController(); signal.abort();
  await assert.rejects(reader.root.fetch(url, {signal:signal.signal}), e => e.name === 'AbortError');
  const second = await reader.root.fetch(url);
  await second.body.cancel();
  let replies = 0;
  owner.runtime.onMessageExternal.fire({__searchBlob:{open:url}}, {id:'another-extension'}, () => replies++);
  owner.runtime.onMessage.fire({__searchBlob:{open:url}}, {id:'another-extension'}, () => replies++);
  await Promise.resolve(); await Promise.resolve();
  assert.equal(replies, 0, 'another extension must never read the registry');
  const third = await reader.root.fetch(url);
  evaluate(owner, `URL.revokeObjectURL(${JSON.stringify(url)})`);
  assert.equal((await third.arrayBuffer()).byteLength, size, 'an open reader retains the Blob after revocation');
  const tiny = evaluate(owner, 'URL.createObjectURL(new Blob([Uint8Array.from([0,1,2,3,4])]))');
  const nativeBefore = nativeFetches;
  await owner.root.fetch(tiny + '#fragment');
  assert.equal(nativeFetches, nativeBefore + 1, 'an own Blob URL with a fragment must remain native');
  owner.root.URL.revokeObjectURL(tiny + '#fragment');
  const withFragment = await reader.root.fetch(tiny + '#fragment');
  assert.equal(withFragment.url, tiny);
  assert.deepEqual(Array.from(new Uint8Array(await withFragment.arrayBuffer())), [0,1,2,3,4]);
  const empty = evaluate(owner, 'URL.createObjectURL(new Blob([]))');
  assert.equal((await (await reader.root.fetch(empty)).arrayBuffer()).byteLength, 0);
  const before = nativeFetches;
  for (const init of [{mode:'same-origin'}, {mode:'no-cors'}, {headers:{Range:'bytes=0-1'}}, {integrity:'sha256-made-up'}]) await reader.root.fetch(empty, init);
  assert.equal(nativeFetches, before + 4, 'range, integrity and explicit origin policies remain native');
  console.log('PASS whole-shim blob streaming, binary integrity, lazy reads, pass-through, abort, cancel, revoke and sender isolation');
})().catch(e => { console.error(e); process.exitCode = 1; });
