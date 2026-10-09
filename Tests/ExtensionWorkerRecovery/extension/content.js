(() => {
  // Every port is kept, including retired ones, so a later native event cannot
  // disappear through garbage collection or be mistaken for a fresh port.
  const held = [];
  const state = { kind: 'content', instance: Math.random().toString(36).slice(2),
    opened: 0, disconnected: 0, replies: 0, ports: [], errors: [] };
  const report = () => document.documentElement.setAttribute('data-search-port-fixture', JSON.stringify(state));
  const fail = error => { state.errors.push(String(error && error.message || error)); report(); };
  const send = (token) => {
    const current = held[held.length - 1], record = state.ports[state.ports.length - 1];
    try {
      current.postMessage({ from: 'content', opened: record.id, token });
      record.sent++; report();
    } catch (error) { fail(error); }
  };
  const connect = (token) => {
    try {
      const current = chrome.runtime.connect({ name: 'content-fixture' });
      const record = { id: ++state.opened, disconnected: 0, replies: 0, sent: 0, messages: [] };
      held.push(current); state.ports.push(record);
      current.onDisconnect.addListener(() => {
        record.disconnected++; state.disconnected++;
        record.lastError = chrome.runtime.lastError?.message || null; report();
      });
      current.onMessage.addListener(message => {
        record.messages.push(message); record.replies++; state.replies++; report();
      });
      send(token || 'initial-content');
    } catch (error) { fail(error); }
  };
  // This is an explicit fixture action, never an automatic reconnect. Only
  // DOM state is exposed to the site's main world, not extension APIs.
  document.addEventListener('click', event => {
    if (event.target.id === 'connect-content') connect(event.target.dataset.token);
    if (event.target.id === 'send-content') send(event.target.dataset.token || 'manual-content');
  });
  connect();
})();
