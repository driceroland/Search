// Deliberately ordinary extension code. Search's own ping listener stays
// untouched, so withholding application replies is not a worker-death test.
let answering = true;
chrome.runtime.onConnect.addListener(port => {
  port.onMessage.addListener(message => {
    if (message.command === 'withhold') { answering = false; return; }
    if (answering) port.postMessage({ echo: message, workerStarted: true });
  });
});
