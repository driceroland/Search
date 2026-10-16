(() => {
  const held = [];
  const state = { kind: 'extension-page', instance: Math.random().toString(36).slice(2),
    opened: 0, disconnected: 0, replies: 0, ports: [], native: [], roundtrips: [], errors: [] };
  const log = message => { document.querySelector('#log').textContent += JSON.stringify(message) + '\n'; };
  const report = () => document.documentElement.setAttribute('data-search-port-fixture', JSON.stringify(state));
  const fail = error => { const message = String(error && error.message || error); state.errors.push(message); log({ error: message }); report(); };
  const send = message => {
    try {
      held[held.length - 1].postMessage(message);
      state.ports[state.ports.length - 1].sent++; report();
    } catch (error) { fail(error); }
  };
  const connect = token => {
    try {
      const current = chrome.runtime.connect({ name: 'page-fixture' });
      const record = { id: ++state.opened, disconnected: 0, replies: 0, sent: 0, messages: [] };
      held.push(current); state.ports.push(record); log({ opened: record.id });
      current.onDisconnect.addListener(() => {
        record.disconnected++; state.disconnected++;
        record.lastError = chrome.runtime.lastError?.message || null;
        log({ port: record.id, disconnected: record.disconnected, lastError: record.lastError }); report();
      });
      current.onMessage.addListener(message => {
        record.messages.push(message); record.replies++; state.replies++;
        log({ port: record.id, reply: message }); report();
      });
      send({ from: 'page', opened: record.id, token: token || 'initial-page' });
    } catch (error) { fail(error); }
  };
  const button = (id, action) => {
    const element = document.querySelector('#' + id);
    element.onclick = () => action(element.dataset.token || id + '-' + Date.now());
  };
  button('connect', connect);
  button('send', token => send({ from: 'page', opened: state.opened, token }));
  button('withhold', token => send({ command: 'withhold', token }));
  button('busy', token => send({ command: 'busy', token, delayMs: 1000, durationMs: 1800 }));
  button('roundtrip', token => {
    const record = { token, status: 'pending', startedAt: Date.now() };
    state.roundtrips.push(record); report();
    Promise.resolve().then(() => chrome.runtime.sendMessage({ fixture: 'roundtrip', token }))
      .then(value => { record.status = 'fulfilled'; record.value = value ?? null; },
        error => { record.status = 'rejected'; record.error = String(error); })
      .finally(() => { record.finishedAt = Date.now(); log({ roundtrip: record }); report(); });
  });
  for (const action of ['wake', 'revive']) button(action, token => {
    const record = { token, action, status: 'pending', startedAt: Date.now() };
    state.native.push(record); report();
    Promise.resolve().then(() => chrome.runtime.sendNativeMessage('search', { api: 'background.' + action, args: [] }))
      .then(reply => { if (reply?.error) throw new Error(reply.error); return reply?.value; })
      .then(value => { record.status = 'fulfilled'; record.value = value ?? null; },
        error => { record.status = 'rejected'; record.error = String(error); })
      .finally(() => { record.finishedAt = Date.now(); log({ native: record }); report(); });
  });
  connect();
})();
