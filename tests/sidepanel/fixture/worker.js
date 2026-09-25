// The button opens the panel, as Chrome's does when asked; a port from the
// panel gets its message back, to prove the panel reaches the worker.
chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {})
chrome.runtime.onConnect.addListener((port) => {
  port.onMessage.addListener((m) => port.postMessage({ echo: m }))
})
