// Ordinary extension code, without overriding any WebKit or Search API. The
// shim's ping listener is untouched. Withholding application replies is NOT
// evidence of an unresponsive shim ping or a genuinely dead worker.
const worker = Date.now() + '-' + Math.random().toString(36).slice(2);
const reportWorker = phase => {
  // Defer native IPC until this startup task completes. An entry note still
  // runs if listener registration throws; only successful registration can
  // schedule the ready note below. Neither note affects the worker's listeners.
  Promise.resolve().then(() => chrome.runtime.sendNativeMessage('search', {
    api: 'debug.error', args: ['fixture-worker-' + phase + ':' + worker]
  })).then(reply => {
    if (reply?.error) throw new Error(reply.error);
  }).catch(error => console.error('fixture-worker-' + phase + ' delivery failed: ' + String(error)));
};
reportWorker('entry');
let answering = true, busyArmed = false;
chrome.runtime.onConnect.addListener(port => {
  port.onMessage.addListener(message => {
    if (message.command === 'withhold') {
      answering = false;
      port.postMessage({ control: 'withhold', token: message.token, answering, worker });
      return;
    }
    if (message.command === 'busy' && !busyArmed) {
      busyArmed = true;
      // A bounded, actual worker event-loop stall. It cannot exceed two
      // seconds and has a finite iteration ceiling even if the clock fails.
      const delayMs = Math.max(0, Math.min(2000, Number(message.delayMs) || 0));
      const durationMs = Math.max(0, Math.min(2000, Number(message.durationMs) || 0));
      const scheduledAt = Date.now() + delayMs;
      port.postMessage({ control: 'busy-armed', token: message.token, scheduledAt, durationMs, worker });
      setTimeout(() => {
        const startedAt = Date.now(), start = performance.now();
        for (let n = 0; n < 100000000 && performance.now() - start < durationMs; n++) { /* deliberately busy */ }
        const finishedAt = Date.now();
        try { port.postMessage({ control: 'busy-done', token: message.token, startedAt, finishedAt, worker }); } catch (_) {}
        busyArmed = false;
      }, delayMs);
      return;
    }
    if (answering) port.postMessage({ echo: message, workerStarted: true, worker });
  });
});
chrome.runtime.onMessage.addListener(message => {
  if (answering && message?.fixture === 'roundtrip') return Promise.resolve({ echo: message, worker });
  return undefined;
});

// A one-shot fixture observation, after both application listeners were
// registered. Context.loaded alone does not establish this startup milestone.
// This uses the existing diagnostic bridge; it does not reconnect any port or
// alter the shim's worker checks, native recovery, or startup deadlines.
reportWorker('ready');
