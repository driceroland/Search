const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[2] || path.join(__dirname, '../../Sources/Search/ExtensionShims.swift'), 'utf8');
const script = source.split('nonisolated static let script = #"""\n')[1].split('\n    """#')[0];
const harness = fs.readFileSync(path.join(__dirname, '../ExtensionWorkerRecovery/shim-harness.js'), 'utf8');
const fixture = vm.runInNewContext(harness + '\nrecoveryFixture', { console });
const state = fixture(false), channels = new Map();
state.root.BroadcastChannel = class {
  constructor(name) { channels.set(name, this); }
  postMessage() {}
};
vm.runInNewContext(script, state.root);
let calls = 0;
state.runtime.onMessage.addListener((message, sender, respond) => { calls++; respond({ok:true}); });
const a = {target:'offscreen', request:{action:'port', details:{id:'made-up', message:{value:[{z:1,a:2}],response_id:'made-up'}}}};
const b = {request:{details:{message:{response_id:'made-up',value:[{a:2,z:1}]},id:'made-up'},action:'port'},target:'offscreen'};
const sender = {id:'fixture',url:'webkit-extension://fixture/worker.js'};
const native = (message, from=sender) => state.runtime.onMessage.fire(message, from, () => {});
const relay = message => {
  channels.get('search-messages').onmessage({data:{relay:message,from:'other-context',url:sender.url}});
  for(const timer of state.timers.splice(0)) if(timer.delay===50) timer.callback();
};
native(b); relay(a);
assert.equal(calls, 1, 'native-first copies must be paired despite reordered nested keys');
relay(a); native(b);
assert.equal(calls, 2, 'relay-first copies must be paired too');
native(b); native(b); relay(a); relay(a);
assert.equal(calls, 4, 'two genuine equal messages must both be delivered exactly once');
native(b,{id:'fixture',url:'https://example.test/'});
native(b,{id:'fixture',url:'https://example.test/'});
assert.equal(calls, 6, 'content messages must not be paired with extension-page messages');
console.log('PASS whole-shim relay deduplication: reordered objects/arrays, either arrival order, repeated equal messages and content isolation');
