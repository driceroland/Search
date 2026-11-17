const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../../Sources/Search/ExtensionShims.swift'), 'utf8');
const script = source.split('nonisolated static let script = #"""\n')[1].split('\n    """#')[0];
const harness = fs.readFileSync(path.join(__dirname, '../ExtensionWorkerRecovery/shim-harness.js'), 'utf8');
const fixture = vm.runInNewContext(harness + '\nrecoveryFixture', { console });
const state = fixture(false);
const seen = [];
state.root.chrome.scripting = {
  registerContentScripts(scripts) { seen.push(['register', scripts]); return Promise.resolve(); },
  updateContentScripts(scripts) { seen.push(['update', scripts]); return Promise.resolve(); },
};
vm.runInNewContext(script, state.root);
const scripting = state.root.chrome.scripting;
scripting.registerContentScripts([
  { id: 'isolated', js: ['page.js'] },
  { id: 'main', js: ['page.js'], world: 'MAIN' },
  { id: 'again', js: ['search-shim.js', 'page.js'] },
]);
scripting.updateContentScripts([{ id: 'plain', js: ['page.js'] }]);
const js = (name) => seen.find((entry) => entry[0] === name)[1].map((script) => script.js);
assert.equal(JSON.stringify(js('register')), JSON.stringify([
  ['search-shim.js', 'page.js'],
  ['search-passkeys.js', 'page.js'],
  ['search-shim.js', 'page.js'],
]));
assert.equal(JSON.stringify(js('update')), JSON.stringify([['search-passkeys.js', 'search-shim.js', 'page.js']]));
console.log('PASS runtime content scripts get the shim, and the page world gets only the passkey patch');
