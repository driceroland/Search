let port, opened = 0, disconnected = 0;
const log = message => { document.querySelector('#log').textContent += JSON.stringify(message) + '\n'; };
const connect = () => {
  const current = chrome.runtime.connect({ name: 'page-fixture' });
  port = current; opened++; log({ opened });
  current.onDisconnect.addListener(() => { disconnected++; log({ disconnected }); });
  current.onMessage.addListener(reply => log({ reply }));
  current.postMessage({ from: 'page', opened });
};
document.querySelector('#connect').onclick = connect;
document.querySelector('#send').onclick = () => port.postMessage({ from: 'page', opened });
document.querySelector('#withhold').onclick = () => port.postMessage({ command: 'withhold' });
for (const action of ['wake', 'revive']) document.querySelector('#' + action).onclick = () =>
  chrome.runtime.sendNativeMessage('search', { api: 'background.' + action, args: [] }).then(log, error => log(String(error)));
connect();
