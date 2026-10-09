(() => {
  const key = '__searchPortRecoveryFixtureV1';
  const previous = globalThis[key];
  // WebKit reinjects declared content scripts when the extension reloads.
  // A rerun in the same world must retain the actual ports and callbacks.
  if (previous && previous.document === document) {
    previous.reinjected();
    return;
  }
  const element = document.documentElement;
  const documentID = element.getAttribute('data-search-port-document');
  const worldReplaced = element.hasAttribute('data-search-port-content-seen');
  const held = [];
  const state = { kind: 'content', instance: Math.random().toString(36).slice(2),
    document: documentID, reinjections: 0, worldReplaced,
    opened: 0, disconnected: 0, replies: 0, ports: [], errors: [] };
  const report = (reason, port = null) => {
    element.setAttribute('data-search-port-fixture', JSON.stringify(state));
    // Strings cross isolated-world boundaries without exporting extension APIs.
    document.dispatchEvent(new CustomEvent('search-port-fixture-report', {
      detail: JSON.stringify({ reason, port, state })
    }));
  };
  globalThis[key] = { document, held, state, reinjected: () => {
    state.reinjections++; report('reinjection');
  } };
  // A surviving DOM marker is evidence of earlier execution, never a source
  // from which to reconstruct ports/counters. A new world cannot claim the
  // original callbacks survived, and must not silently open a replacement.
  if (worldReplaced || !documentID) {
    state.errors.push(worldReplaced ? 'Isolated fixture state lost in an existing document' : 'Main document fixture is not initialized');
    report(worldReplaced ? 'world-replaced' : 'error');
    return;
  }
  element.setAttribute('data-search-port-content-seen', state.instance);
  report('boot');
  const fail = error => { state.errors.push(String(error && error.message || error)); report('error'); };
  const send = (token) => {
    const current = held[held.length - 1], record = state.ports[state.ports.length - 1];
    try {
      current.postMessage({ from: 'content', opened: record.id, token });
      record.sent++; report('send', record.id);
    } catch (error) { fail(error); }
  };
  const connect = (token) => {
    try {
      const current = chrome.runtime.connect({ name: 'content-fixture' });
      const record = { id: ++state.opened, disconnected: 0, replies: 0, sent: 0, messages: [] };
      held.push(current); state.ports.push(record);
      current.onDisconnect.addListener(() => {
        record.disconnected++; state.disconnected++;
        record.lastError = chrome.runtime.lastError?.message || null; report('disconnect', record.id);
      });
      current.onMessage.addListener(message => {
        record.messages.push(message); record.replies++; state.replies++; report('message', record.id);
      });
      report('connect', record.id);
      send(token || 'initial-content');
    } catch (error) { fail(error); }
  };
  // Installed once in this actual world. Every fresh connection remains an
  // explicit click; neither reinjection nor a disconnect calls connect().
  document.addEventListener('click', event => {
    if (event.target.id === 'connect-content') connect(event.target.dataset.token);
    if (event.target.id === 'send-content') send(event.target.dataset.token || 'manual-content');
  });
  connect();
})();
