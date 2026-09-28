"use strict";

(() => {
  const PASSKEY = "BrowserFido2UserInterfaceServiceMessage";
  const SESSION = "search-fixture-github-assertion";
  const cycle = Number(new URLSearchParams(location.search).get("cycle"));

  async function disposalProbe() {
    let sync = 0;
    let async = 0;
    const symbols = {
      dispose: typeof Symbol.dispose === "symbol",
      asyncDispose: typeof Symbol.asyncDispose === "symbol",
    };
    if (symbols.dispose) {
      const resource = { [Symbol.dispose]() { sync += 1; } };
      try { /* mirrors Bitwarden's explicit-resource helper */ }
      finally { resource[Symbol.dispose](); }
    }
    if (symbols.asyncDispose) {
      const resource = { async [Symbol.asyncDispose]() { await Promise.resolve(); async += 1; } };
      try { /* asynchronous resource helper */ }
      finally { await resource[Symbol.asyncDispose](); }
    }
    return { ...symbols, syncDisposals: sync, asyncDisposals: async };
  }
  function plainWindow(window) {
    return window && {
      id: window.id, type: window.type, focused: window.focused,
      left: window.left, top: window.top, width: window.width, height: window.height,
      tabs: Array.isArray(window.tabs) ? window.tabs.map((tab) => ({
        id: tab.id, index: tab.index, url: tab.url, windowId: tab.windowId,
      })) : null,
    };
  }
  function plainTab(tab) {
    return tab && { id: tab.id, index: tab.index, url: tab.url, windowId: tab.windowId };
  }
  function callbackCurrent() {
    return new Promise((resolve, reject) => {
      chrome.windows.getCurrent({ populate: true }, (window) => {
        const error = chrome.runtime.lastError;
        if (error) reject(new Error(error.message));
        else resolve(window);
      });
    });
  }
  function senderInfo(sender) {
    return {
      id: sender && sender.id || null,
      url: sender && sender.url || null,
      origin: sender && sender.origin || null,
      tab: sender && sender.tab ? {
        id: sender.tab.id ?? null, index: sender.tab.index ?? null,
        url: sender.tab.url ?? null, windowId: sender.tab.windowId ?? null,
      } : null,
      frameId: (sender && sender.frameId) ?? null,
    };
  }

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message && message.command === PASSKEY && message.sessionId === SESSION && message.type === "PickCredentialRequest") {
      void chrome.runtime.sendMessage({
        kind: "fixture.popupHeard", cycle, raw: JSON.stringify(message), messageSender: senderInfo(sender),
      }).catch(() => {});
      void chrome.runtime.sendMessage({
        command: PASSKEY, type: "PickCredentialResponse", sessionId: SESSION,
        cipherId: "fixture-cipher", userVerified: true,
      }).catch(() => {});
      return;
    }
    if (message && message.kind === "fixture.checkPopupCurrent" && message.cycle === cycle) {
      Promise.all([
        chrome.windows.getCurrent({ populate: true }),
        callbackCurrent(),
        chrome.tabs.getCurrent(),
      ]).then(([window, callbackWindow, ownTab]) => chrome.runtime.sendMessage({
        kind: "fixture.popupCurrent", cycle, window: plainWindow(window),
        callbackWindow: plainWindow(callbackWindow), ownTab: plainTab(ownTab),
      })).then(() => sendResponse({ ok: true }), () => sendResponse({ ok: false }));
      return true;
    }
  });

  (async () => {
    const probe = await disposalProbe();
    const [current, callbackWindow, ownTab] = await Promise.all([
      chrome.windows.getCurrent({ populate: true }),
      callbackCurrent(),
      chrome.tabs.getCurrent(),
    ]);
    await chrome.runtime.sendMessage({ kind: "fixture.popupReady", cycle, report: {
      probe, window: plainWindow(current), callbackWindow: plainWindow(callbackWindow), ownTab: plainTab(ownTab),
    } });
  })().catch((error) => { document.title = `fixture error: ${String(error && error.message || error)}`; });
})();
