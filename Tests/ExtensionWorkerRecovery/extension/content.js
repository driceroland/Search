(() => {
  let port, opened = 0, disconnected = 0, replies = 0;
  const report = () => document.documentElement.setAttribute('data-search-port-fixture',
    JSON.stringify({ opened, disconnected, replies }));
  const connect = () => {
    port = chrome.runtime.connect({ name: 'content-fixture' }); opened++;
    port.onDisconnect.addListener(() => { disconnected++; report(); });
    port.onMessage.addListener(() => { replies++; report(); });
    port.postMessage({ from: 'content', opened }); report();
  };
  connect();
  // The fixture page's buttons are explicit user actions. No reconnect is
  // automatic: this action is the extension choosing to open a fresh port.
  document.addEventListener('click', event => {
    if (event.target.id === 'connect-content') connect();
    if (event.target.id === 'send-content') {
      try { port.postMessage({ from: 'content', opened }); } catch (error) { console.log(error.message); }
    }
  });
})();
