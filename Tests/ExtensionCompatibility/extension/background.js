"use strict";

const PASSKEY = "BrowserFido2UserInterfaceServiceMessage";
const SESSION = "search-fixture-github-assertion";
const pickRequest = {
  command: PASSKEY,
  type: "PickCredentialRequest",
  sessionId: SESSION,
  cipherIds: ["fixture-cipher"],
  userVerification: true,
  fallbackSupported: false,
};
const tracked = new Set();
const removed = new Map();
const responses = [];
const popupReports = new Map();
const popupCurrent = new Map();
const broadcastCycles = new Set();
const requestEchoes = [];
const popupHeard = [];

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

async function disposalProbe() {
  let sync = 0;
  let async = 0;
  const symbols = {
    dispose: typeof Symbol.dispose === "symbol",
    asyncDispose: typeof Symbol.asyncDispose === "symbol",
  };
  if (symbols.dispose) {
    const resource = { [Symbol.dispose]() { sync += 1; } };
    try { /* mirrors the explicit-resource helper used by Bitwarden bundles */ }
    finally { resource[Symbol.dispose](); }
  }
  if (symbols.asyncDispose) {
    const resource = { async [Symbol.asyncDispose]() { await Promise.resolve(); async += 1; } };
    try { /* same disposal path for asynchronous resources */ }
    finally { await resource[Symbol.asyncDispose](); }
  }
  return { ...symbols, syncDisposals: sync, asyncDisposals: async };
}
let workerProbe;
const workerProbePromise = disposalProbe().then((probe) => (workerProbe = probe));

function plainWindow(window) {
  return window && {
    id: window.id, type: window.type, focused: window.focused,
    left: window.left, top: window.top, width: window.width, height: window.height,
  };
}

chrome.windows.onRemoved.addListener((windowId) => {
  if (!tracked.has(windowId)) return;
  const count = (removed.get(windowId) || 0) + 1;
  removed.set(windowId, count);
  void chrome.runtime.sendMessage({ kind: "fixture.windowRemoved", windowId, count }).catch(() => {});
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.command === PASSKEY && message.type === "PickCredentialRequest") {
    requestEchoes.push({ raw: JSON.stringify(message), sender: senderInfo(sender) });
    return;
  }
  if (message && message.command === PASSKEY && message.type === "PickCredentialResponse") {
    responses.push({
      raw: JSON.stringify(message),
      sender: senderInfo(sender),
      sessionId: message.sessionId, cipherId: message.cipherId, userVerified: message.userVerified,
    });
    sendResponse({ ok: true });
    return true;
  }
  if (!message || typeof message.kind !== "string") return;

  switch (message.kind) {
    case "fixture.pageReady":
      workerProbePromise.then((probe) => sendResponse({ ok: true, probe }));
      return true;
    case "fixture.trackWindow":
      tracked.add(message.windowId);
      sendResponse({ ok: true });
      return;
    case "fixture.popupReady":
      popupReports.set(message.cycle, message.report);
      sendResponse({ ok: true });
      if (!broadcastCycles.has(message.cycle)) {
        broadcastCycles.add(message.cycle);
        // A popup's bootstrap-ready signal is followed by Bitwarden's worker
        // sending the assertion picker state to its own extension pages.
        Promise.resolve().then(() => {
          void chrome.runtime.sendMessage(pickRequest).catch(() => {});
          void chrome.runtime.sendMessage(pickRequest).catch(() => {});
        });
      }
      return;
    case "fixture.askPopupCurrent":
      void chrome.runtime.sendMessage({ kind: "fixture.checkPopupCurrent", cycle: message.cycle }).catch(() => {});
      sendResponse({ ok: true });
      return;
    case "fixture.popupCurrent":
      popupCurrent.set(message.cycle, {
        window: message.window,
        callbackWindow: message.callbackWindow,
        ownTab: message.ownTab,
      });
      sendResponse({ ok: true });
      return;
    case "fixture.popupHeard":
      popupHeard.push({ cycle: message.cycle, raw: message.raw, messageSender: message.messageSender, sender: senderInfo(sender) });
      sendResponse({ ok: true });
      return;
    case "fixture.snapshot":
      sendResponse({
        workerProbe,
        requestEchoes: requestEchoes.slice(),
        popupHeard: popupHeard.slice(),
        responses: responses.slice(),
        removed: [...removed.entries()].map(([windowId, count]) => ({ windowId, count })),
        popupReports: [...popupReports.entries()].map(([cycle, report]) => ({ cycle, report })),
        popupCurrent: [...popupCurrent.entries()].map(([cycle, current]) => ({ cycle, ...current })),
      });
      return;
  }
});
