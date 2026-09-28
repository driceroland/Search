"use strict";

(() => {
  const PASSKEY = "BrowserFido2UserInterfaceServiceMessage";
  const SESSION = "search-fixture-github-assertion";
  const received = [];
  const removedEvents = [];
  const checks = [];
  window.__fixtureResult = null;

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

  chrome.runtime.onMessage.addListener((message, sender) => {
    if (message && message.command === PASSKEY && message.sessionId === SESSION && message.type === "PickCredentialRequest") {
      received.push({ raw: JSON.stringify(message), sender: senderInfo(sender) });
    }
    if (message && message.kind === "fixture.windowRemoved") {
      removedEvents.push({ windowId: message.windowId, raw: JSON.stringify(message), sender: senderInfo(sender) });
    }
  });

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const assert = (condition, label, detail) => {
    checks.push({ label, ok: !!condition, detail: detail === undefined ? null : detail });
  };
  const geometry = (window) => ({
    id: window && window.id, type: window && window.type, focused: window && window.focused,
    left: window && window.left, top: window && window.top,
    width: window && window.width, height: window && window.height,
  });
  async function snapshot() {
    return await chrome.runtime.sendMessage({ kind: "fixture.snapshot" });
  }
  async function waitFor(label, predicate, timeout = 10000) {
    const end = Date.now() + timeout;
    let last;
    while (Date.now() < end) {
      last = await snapshot();
      if (predicate(last)) return last;
      await sleep(60);
    }
    throw new Error(`timed out waiting for ${label}: ${JSON.stringify(last)}`);
  }
  async function send(message) {
    const result = await chrome.runtime.sendMessage(message);
    if (!result || result.ok !== true) throw new Error(`worker did not acknowledge ${message.kind}: ${JSON.stringify(result)}`);
    return result;
  }
  function popupEntry(snapshot, cycle, key) {
    const entry = (snapshot[key] || []).find((item) => item.cycle === cycle);
    return entry && (key === "popupReports" ? entry.report : entry.window);
  }
  function expectGeometry(actual, expected, label) {
    for (const key of ["left", "top", "width", "height"]) {
      assert(actual && actual[key] === expected[key], `${label} ${key}`, { got: actual && actual[key], want: expected[key] });
    }
  }
  function callbackUpdate(id, details) {
    return new Promise((resolve, reject) => {
      chrome.windows.update(id, details, (window) => {
        const error = chrome.runtime.lastError;
        if (error) reject(new Error(error.message));
        else resolve(window);
      });
    });
  }

  async function run() {
    const pageProbe = await disposalProbe();
    assert(pageProbe.dispose && pageProbe.asyncDispose, "page has both disposal symbols", pageProbe);
    assert(pageProbe.syncDisposals === 1 && pageProbe.asyncDisposals === 1, "page disposal methods ran once", pageProbe);
    const pageReady = await send({ kind: "fixture.pageReady", probe: pageProbe });
    assert(pageReady.probe && pageReady.probe.dispose && pageReady.probe.asyncDispose, "worker has both disposal symbols", pageReady.probe);
    assert(pageReady.probe.syncDisposals === 1 && pageReady.probe.asyncDisposals === 1, "worker disposal methods ran once", pageReady.probe);

    const current = await chrome.windows.getCurrent();
    assert(Number.isInteger(current && current.id) && current.width > 0 && current.height > 0,
      "windows.getCurrent returns real geometry in extension page", geometry(current));
    const lastFocused = await chrome.windows.getLastFocused();
    assert(lastFocused && lastFocused.id === current.id, "initial current window is last focused", geometry(lastFocused));

    const cycles = [
      { left: 162, top: 118, width: 428, height: 318 },
      { left: 208, top: 154, width: 452, height: 342 },
    ];
    const callbackFrames = [
      { left: 185, top: 136, width: 446, height: 334 },
      { left: 230, top: 176, width: 474, height: 356 },
    ];
    const opened = [];

    try {
      for (let cycle = 1; cycle <= 2; cycle += 1) {
        const priorRequests = received.length;
        const beforeResponses = (await snapshot()).responses.length;
        const beforeFocus = await chrome.windows.getLastFocused();
        const created = await chrome.windows.create({
          url: chrome.runtime.getURL(`popup.html?cycle=${cycle}`),
          type: "popup", focused: false,
          left: 92, top: 84, width: 390, height: 280,
        });
        opened.push(created.id);
        assert(Number.isInteger(created && created.id) && created.type === "popup", `popup ${cycle} created`, geometry(created));
        assert(created.focused === false, `popup ${cycle} respects focused:false`, geometry(created));
        const afterFocus = await chrome.windows.getLastFocused();
        assert(afterFocus && afterFocus.id === beforeFocus.id, `popup ${cycle} preserves last-focused window`, geometry(afterFocus));
        await send({ kind: "fixture.trackWindow", windowId: created.id });

        const ready = await waitFor(`popup ${cycle} bootstrap`, (state) => !!popupEntry(state, cycle, "popupReports"));
        const report = popupEntry(ready, cycle, "popupReports");
        assert(report.window && Number.isInteger(report.window.id) && report.window.width > 0 && report.window.height > 0,
          `popup ${cycle} windows.getCurrent returns geometry`, report.window);
        assert(report.window && report.window.id === created.id, `popup ${cycle} windows.getCurrent id`, report.window);
        assert(report.callbackWindow && report.callbackWindow.id === created.id,
          `popup ${cycle} callback getCurrent id`, report.callbackWindow);
        const populatedTabs = (report.callbackWindow && report.callbackWindow.tabs) || [];
        assert(report.ownTab && populatedTabs.some((tab) =>
          tab.id === report.ownTab.id && tab.windowId === created.id),
          `popup ${cycle} populated getCurrent includes its own tab`, { ownTab: report.ownTab, window: report.callbackWindow });
        assert(report.probe && report.probe.dispose && report.probe.asyncDispose
          && report.probe.syncDisposals === 1 && report.probe.asyncDisposals === 1,
          `popup ${cycle} disposal support`, report.probe);

        let updated = created;
        const update = async (label, operation, expected) => {
          try {
            const actual = await operation();
            expectGeometry(geometry(actual), expected, label);
            updated = actual || updated;
          } catch (error) {
            assert(false, label, String(error && error.message || error));
          }
        };
        if (cycle === 1) {
          await update("promise update geometry", () => chrome.windows.update(created.id, cycles[0]), cycles[0]);
          const partialSize = { width: callbackFrames[0].width, height: callbackFrames[0].height };
          await update("callback size-only geometry", () => callbackUpdate(created.id, partialSize), { ...geometry(updated), ...partialSize });
        } else {
          await update("callback update geometry", () => callbackUpdate(created.id, callbackFrames[1]), callbackFrames[1]);
          const partialPosition = { left: cycles[1].left + 11, top: cycles[1].top + 9 };
          await update("promise position-only geometry", () => chrome.windows.update(created.id, partialPosition), { ...geometry(updated), ...partialPosition });
        }

        try {
          await send({ kind: "fixture.askPopupCurrent", cycle });
          const checked = await waitFor(`popup ${cycle} updated getCurrent`, (state) => !!popupEntry(state, cycle, "popupCurrent"));
          const popupWindow = popupEntry(checked, cycle, "popupCurrent");
          assert(popupWindow && popupWindow.id === created.id, `popup ${cycle} getCurrent id after update`, popupWindow);
          expectGeometry(popupWindow, geometry(updated), `popup ${cycle} getCurrent after update`);
          const currentEntry = (checked.popupCurrent || []).find((entry) => entry.cycle === cycle);
          assert(currentEntry && currentEntry.callbackWindow && currentEntry.callbackWindow.id === created.id,
            `popup ${cycle} callback getCurrent id after update`, currentEntry && currentEntry.callbackWindow);
          const updatedTabs = (currentEntry && currentEntry.callbackWindow && currentEntry.callbackWindow.tabs) || [];
          assert(currentEntry && currentEntry.ownTab && updatedTabs.some((tab) =>
            tab.id === currentEntry.ownTab.id && tab.windowId === created.id),
            `popup ${cycle} callback populate includes its own tab after update`, currentEntry);
          expectGeometry(currentEntry && currentEntry.callbackWindow, geometry(updated), `popup ${cycle} callback getCurrent after update`);
        } catch (error) {
          assert(false, `popup ${cycle} getCurrent after update`, String(error && error.message || error));
        }

        try {
          await waitFor(`popup ${cycle} passkey request/replies`, (state) =>
            received.length >= priorRequests + 2 && state.responses.length >= beforeResponses + 2);
        } catch (error) {
          assert(false, `popup ${cycle} Bitwarden message flow`, String(error && error.message || error));
        }
        await sleep(300);
        const settled = await snapshot();
        assert(received.length === priorRequests + 2, `popup ${cycle} received both identical Bitwarden requests once`, received.length - priorRequests);
        assert(settled.responses.length === beforeResponses + 2, `popup ${cycle} returned two Bitwarden-style picker responses`, settled.responses.slice(beforeResponses));
        assert(settled.responses.slice(beforeResponses).every((message) => message.sessionId === SESSION
          && message.cipherId === "fixture-cipher" && message.userVerified === true),
          `popup ${cycle} response shape`, settled.responses.slice(beforeResponses));

        await chrome.windows.remove(created.id);
        try {
          await waitFor(`popup ${cycle} background windows.onRemoved`, (state) =>
            (state.removed || []).some((entry) => entry.windowId === created.id && entry.count > 0), 3000);
        } catch (error) {
          assert(false, `popup ${cycle} background windows.onRemoved`, String(error && error.message || error));
        }
        const all = await chrome.windows.getAll();
        assert(!all.some((window) => window.id === created.id), `popup ${cycle} is absent from windows.getAll after close`, created.id);
        await sleep(300);
        const afterClose = await snapshot();
        const workerRemovalCount = (afterClose.removed || []).find((entry) => entry.windowId === created.id)?.count || 0;
        assert(removedEvents.filter((event) => event.windowId === created.id).length === 1,
          `popup ${cycle} emits one windows.onRemoved notice to the extension page`, removedEvents.filter((event) => event.windowId === created.id));
        assert(workerRemovalCount === 1, `popup ${cycle} background windows.onRemoved fires exactly once`, workerRemovalCount);
      }
    } finally {
      const all = await chrome.windows.getAll();
      await Promise.all(opened.filter((id) => all.some((window) => window.id === id))
        .map((id) => chrome.windows.remove(id).catch(() => undefined)));
    }

    const finalState = await snapshot();
    return { ok: checks.every((item) => item.ok), checks, received, removedEvents, finalState };
  }

  run().then((result) => { window.__fixtureResult = result; }, (error) => {
    window.__fixtureResult = { ok: false, error: String(error && error.message || error), checks, received, removedEvents, finalState: null };
  });
})();
