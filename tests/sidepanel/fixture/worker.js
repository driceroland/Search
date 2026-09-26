// The button opens the panel, as Chrome's does when asked; a port from the
// panel gets its message back, to prove the panel reaches the worker.
chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {})
const panelEvents = []
chrome.sidePanel.onOpened.addListener((info) => panelEvents.push('opened:' + (info && info.path)))
chrome.sidePanel.onClosed.addListener((info) => panelEvents.push('closed:' + (info && info.path)))
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message !== 'panel-events') return
  sendResponse(panelEvents.slice())
  return true
})
chrome.runtime.onConnect.addListener((port) => {
  port.onMessage.addListener((m) => port.postMessage({ echo: m }))
})
