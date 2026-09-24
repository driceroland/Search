#!/usr/bin/env python3
"""Exercise real offscreen documents through an isolated Search bench.

Start Search with SEARCH_PROBE=<world> SEARCH_MEASURE=1 and enable its bench,
then run: python3 tests/offscreen.py --world <world>
Temporary extensions use real WebKit APIs; no browser APIs are mocked.
"""

import argparse
import json
from pathlib import Path
import runpy
import socket
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]
BENCH = runpy.run_path(str(ROOT / "bench"))
HOST = r"""
const timeout = promise => Promise.race([promise, new Promise((_, reject) =>
  setTimeout(() => reject(new Error('extension API timed out')), 5000))]);
const contexts = filter => chrome.runtime.getContexts({contextTypes: ['OFFSCREEN_DOCUMENT'], ...filter});
const create = url => chrome.offscreen.createDocument({url, reasons: ['DOM_SCRAPING'],
  justification: 'Exercise real offscreen document lifecycle and message readiness.'});
if (window.owner === 'A') chrome.runtime.onMessage.addListener((message, sender) => {
  if (message.type === 'OFFSCREEN_FRAME_RESULT')
    window.frameSource = {url: sender.url, frameId: sender.frameId, id: sender.id};
});
window.beginPending = () => {
  window.pendingCreate = create('pending.html').then(() => ({resolved: true}), error => ({error: String(error)}));
};
window.beginDelayed = async () => {
  // Exercise the owned native waiter directly, using the real sender captured
  // by the preceding iframe test. Ordinary WebKit runtime channels have their
  // own teardown timing, separate from the relay this browser owns.
  const state = await chrome.runtime.sendMessage({type: 'OFFSCREEN_FRAME_STATUS'});
  const startedAt = performance.now();
  const response = chrome.runtime.sendNativeMessage('search', {api: 'offscreen.sendMessage',
    args: [crypto.randomUUID(), {type: 'OFFSCREEN_DELAY'}, state.rawSender]});
  const timing = () => ({elapsedMs: performance.now() - startedAt, finishedAt: performance.now()});
  window.delayedRelay = response.then(reply => ({reply, ...timing()}), error => ({error: String(error), ...timing()}));
};
window.run = async function(command, previous) {
  window.result = null;
  window.operation = command;
  window.lastCheck = null;
  const result = {checks: [], errors: [], context: null};
  const check = (ok, message) => {
    window.lastCheck = message;
    result.checks.push({ok: !!ok, message});
    if (!ok) result.errors.push(message);
  };
  try {
    if (command === 'unanswered') {
      try {
        const value = await timeout(chrome.runtime.sendMessage({type: 'UNHANDLED_PROBE'}));
        check(value === undefined, 'a genuinely unanswered message settles without a fabricated result');
      } catch (error) {
        check(!String(error).includes('timed out'), 'a genuinely unanswered message settles without hanging');
      }
    } else if (command === 'empty' || command === 'close') {
      if (command === 'close') await timeout(chrome.offscreen.closeDocument());
      check(!(await chrome.offscreen.hasDocument()), command + ': hasDocument is false');
      check((await contexts({})).length === 0, command + ': no offscreen contexts remain');
    } else if (command === 'cancel-pending') {
      check((await contexts({})).length === 0, 'loading document is not advertised as a ready context');
      await timeout(chrome.offscreen.closeDocument());
      const outcome = await timeout(window.pendingCreate);
      check(!!outcome.error, 'closing during initial load rejects the pending create');
      check(!(await chrome.offscreen.hasDocument()) && (await contexts({})).length === 0,
        'cancellation clears the document slot and discovery');
    } else if (command === 'invalid') {
      for (const url of ['https://unrelated.invalid/offscreen.html', 'missing-document.html']) {
        let rejected = false;
        try { await timeout(create(url)); }
        catch (error) { rejected = !String(error).includes('timed out'); }
        check(rejected, url + ': creation rejects');
        check(!(await chrome.offscreen.hasDocument()) && (await contexts({})).length === 0,
          url + ': failed creation leaves no document or context');
      }
    } else if (command === 'cancel-delayed') {
      const closedAt = performance.now();
      await timeout(chrome.offscreen.closeDocument());
      const outcome = await Promise.race([window.delayedRelay || Promise.resolve({missing: true}),
        new Promise(resolve => setTimeout(() => resolve({timeout: true}), 1000))]);
      result.nativeRelay = outcome;
      check(!outcome.timeout && /closed/i.test(String(outcome.error || outcome.reply?.error || '')) &&
        outcome.finishedAt >= closedAt && outcome.finishedAt - closedAt < 1000,
        'closing promptly rejects the actual native offscreen relay waiter');
      check(!(await chrome.offscreen.hasDocument()) && (await contexts({})).length === 0,
        'closing a document with an outstanding reply clears its slot');
    } else if (command === 'create' || command === 'absolute') {
      check(!(await chrome.offscreen.hasDocument()), 'starts without a document');
      const tabsBefore = await chrome.tabs.query({});
      await timeout(create(command === 'absolute' ? chrome.runtime.getURL('offscreen.html') : 'offscreen.html'));
      try {
        const reply = await timeout(chrome.runtime.sendMessage({type: 'OFFSCREEN_ECHO'}));
        check(reply?.owner === window.owner && reply?.title === 'Offscreen fixture',
          'create resolves with page scripts ready for immediate runtime messaging');
      } catch (error) { check(false, 'immediate runtime message: ' + error); }
      check(await chrome.offscreen.hasDocument(), 'hasDocument reports the created document');
      const background = await chrome.runtime.getContexts({contextTypes: ['BACKGROUND']});
      check(background.length === (window.owner === 'A' ? 1 : 0),
        'background discovery remains available independently of offscreen discovery');
      const found = await contexts({});
      check(found.length === 1, 'getContexts returns exactly one own offscreen document');
      const context = found[0];
      result.context = context || null;
      if (context) {
        const url = chrome.runtime.getURL('offscreen.html');
        const origin = new URL(url).protocol + '//' + new URL(url).host;
        check(typeof context.contextId === 'string' && !!context.contextId &&
          typeof context.documentId === 'string' && !!context.documentId, 'context and document IDs are present');
        check(context.contextType === 'OFFSCREEN_DOCUMENT' && context.documentUrl === url &&
          context.documentOrigin === origin && context.frameId === 0 && context.tabId === -1 &&
          context.windowId === -1 && context.incognito === false, 'offscreen context metadata is accurate');
        const filters = {contextIds: [context.contextId], contextTypes: ['OFFSCREEN_DOCUMENT'],
          documentIds: [context.documentId], documentOrigins: [origin], documentUrls: [url],
          frameIds: [0], tabIds: [-1], windowIds: [-1]};
        const wrong = {contextIds: ['missing'], contextTypes: ['SIDE_PANEL'], documentIds: ['missing'],
          documentOrigins: ['https://unrelated.invalid'], documentUrls: [url + '?unrelated'],
          frameIds: [999], tabIds: [999], windowIds: [999]};
        for (const [key, values] of Object.entries(filters)) {
          check((await contexts({[key]: values})).length === 1, key + ': matching filter');
          check((await contexts({[key]: wrong[key]})).length === 0, key + ': nonmatching filter');
          check((await contexts({[key]: []})).length === 0, key + ': empty filter matches nothing');
        }
        check((await contexts({...filters, incognito: false})).length === 1, 'all matching filters combine');
        check((await contexts({incognito: true})).length === 0, 'incognito filter excludes normal document');
        check((await chrome.runtime.getContexts({})).some(item => item.contextId === context.contextId),
          'unrestricted context query includes the document');
        if (previous) check(context.contextId !== previous.contextId && context.documentId !== previous.documentId,
          'recreation assigns fresh context and document IDs');
      }
      let duplicateRejected = false;
      try { await timeout(create('offscreen.html')); }
      catch (error) { duplicateRejected = !String(error).includes('timed out'); }
      check(duplicateRejected, 'duplicate creation rejects');
      const tabsAfter = await chrome.tabs.query({});
      const state = tabs => JSON.stringify(tabs.map(tab => [tab.id, tab.active]).sort());
      check(state(tabsBefore) === state(tabsAfter), 'creation does not add visible tabs or change selection');
    } else if (command === 'slow-worker') {
      const nonce = crypto.randomUUID();
      const startedAt = performance.now();
      const reply = await Promise.race([chrome.runtime.sendMessage({type: 'SLOW_WORKER', nonce}),
        new Promise((_, reject) => setTimeout(() => reject(new Error('slow worker response timed out')), 18000))]);
      result.elapsedMs = performance.now() - startedAt;
      check(reply?.from === 'worker' && reply?.nonce === nonce,
        'uninterested extension pages do not beat the worker response after twelve seconds');
    } else if (command === 'iframe') {
      const reply = await timeout(chrome.runtime.sendMessage({type: 'OFFSCREEN_FRAME'}));
      check(reply?.owner === window.owner && reply?.text === 'Offscreen iframe DOM result',
        'iframe content script forwards real DOM text through runtime messaging');
    } else if (command === 'frame-status') {
      const status = await timeout(chrome.runtime.sendMessage({type: 'OFFSCREEN_FRAME_STATUS'}));
      result.frameStatus = status;
      result.frameSource = window.frameSource || null;
      check(status?.deliveries === 1, 'iframe message reaches its offscreen listener exactly once');
      check(status?.sender?.url === window.frameURL && status?.sender?.frameId > 0 &&
        status?.sender?.id === chrome.runtime.id && (window.owner === 'B' ||
          JSON.stringify(status.sender) === JSON.stringify(window.frameSource)),
        'iframe message preserves the original sender URL, frame ID and extension ID');
    } else if (command === 'isolated') {
      const found = await contexts({});
      check(found.length === 1 && found[0].contextId === previous?.contextId,
        'another extension lifecycle leaves own context unchanged');
      const reply = await timeout(chrome.runtime.sendMessage({type: 'OFFSCREEN_ECHO'}));
      check(reply?.owner === window.owner, 'runtime messages reach only own offscreen document');
    } else {
      throw new Error('Unknown regression command: ' + command);
    }
  } catch (error) { result.errors.push(String(error)); }
  window.result = result;
};
"""
DOCUMENT = r"""
let frameReply = null;
let frame = null;
let frameDeliveries = 0;
let frameSender = null;
let rawFrameSender = null;
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message.type === 'OFFSCREEN_ECHO') respond({owner: OWNER, title: document.title});
  if (message.type === 'OFFSCREEN_FRAME' || message.type === 'OFFSCREEN_DELAY_FRAME') {
    frameReply = respond;
    frame?.remove();
    frame = document.createElement('iframe');
    frame.src = FRAME_URL + (message.type === 'OFFSCREEN_DELAY_FRAME' ? '&delayed=1' : '');
    document.body.append(frame);
    return true;
  }
  if (message.type === 'OFFSCREEN_DELAY') {
    fetch(new URL('/delay-armed', FRAME_URL), {method: 'POST', body: JSON.stringify({owner: OWNER})});
    setTimeout(() => {
      fetch(new URL('/delay-fired', FRAME_URL), {method: 'POST', body: JSON.stringify({owner: OWNER})});
      respond({received: true});
      if (frameReply) frameReply({late: true});
    }, 2000);
    return true;
  }
  if (message.type === 'OFFSCREEN_FRAME_RESULT') {
    frameDeliveries++;
    frameSender = {url: sender.url, frameId: sender.frameId, id: sender.id};
    rawFrameSender = sender;
    if (frameReply) frameReply({owner: message.owner, text: message.text});
    frameReply = null;
    respond({received: true});
  }
  if (message.type === 'OFFSCREEN_FRAME_STATUS') respond({deliveries: frameDeliveries, sender: frameSender, rawSender: rawFrameSender});
});
"""
CONTENT = r"""
(async () => {
  if (new URL(location.href).searchParams.get('owner') !== OWNER) return;
  let result;
  try {
    const delayed = new URL(location.href).searchParams.has('delayed');
    const reply = await chrome.runtime.sendMessage({type: delayed ? 'OFFSCREEN_DELAY' : 'OFFSCREEN_FRAME_RESULT', owner: OWNER,
      text: document.body.textContent});
    result = {owner: OWNER, received: reply?.received === true};
  } catch (error) { result = {owner: OWNER, error: String(error)}; }
  await fetch('/ack', {method: 'POST', body: JSON.stringify(result)});
})();
"""
BACKGROUND = r"""
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (message.type !== 'SLOW_WORKER') return;
  setTimeout(() => respond({from: 'worker', nonce: message.nonce}), 12000);
  return true;
});
"""


class PendingImage(BaseHTTPRequestHandler):
    def do_GET(self):
        is_frame = self.path.split("?", 1)[0] == "/frame"
        if not is_frame:
            self.server.started.set()
            self.server.release.wait(20)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8" if is_frame else "image/svg+xml")
            self.end_headers()
            self.wfile.write(b'<!doctype html><body>Offscreen iframe DOM result</body>' if is_frame else
                             b'<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>')
        except (BrokenPipeError, ConnectionResetError):
            pass  # Cancelling the offscreen load can close the image request.

    def do_POST(self):
        result = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        if self.path == "/delay-armed":
            self.server.delayed_armed.set()
        elif self.path == "/delay-fired":
            self.server.delayed_fired.set()
        else:
            with self.server.acks_lock:
                self.server.acks[result["owner"]] = result
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--world", required=True, help="isolated SEARCH_PROBE world")
    args = parser.parse_args()
    if not args.world or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in args.world):
        parser.error("world must contain lowercase ASCII letters, digits or hyphens")
    socket.setdefaulttimeout(20)
    socket_path = str(Path(BENCH["folder"](args.world)) / "bench.sock")
    extensions, hosts, results = {}, {}, []
    server = ThreadingHTTPServer(("127.0.0.1", 0), PendingImage)
    server.started, server.release = threading.Event(), threading.Event()
    server.delayed_armed, server.delayed_fired = threading.Event(), threading.Event()
    server.acks, server.acks_lock = {}, threading.Lock()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{server.server_port}"

    def ask(verb, **fields):
        response = BENCH["ask"](socket_path, {"do": verb, **fields})
        if "error" in response:
            raise RuntimeError(response["error"])
        return response

    def poll(read, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = read()
            if value:
                return value
            time.sleep(0.1)
        raise RuntimeError("test controller timed out")

    def loaded(label):
        return any(item["id"] == extensions[label] and item["loaded"]
                   for item in ask("extensions")["extensions"])

    def open_host(label):
        hosts[label] = ask("ext-page", id=extensions[label], path="host.html")["id"]
        poll(lambda: ask("eval", id=hosts[label], js="typeof window.run === 'function'").get("value"))

    def run(label, command, previous=None):
        before = [(tab["id"], tab["active"]) for tab in ask("tabs")["tabs"]]
        js = f"window.run({json.dumps(command)}, {json.dumps(previous)}); true"
        ask("eval", id=hosts[label], js=js)
        try:
            result = poll(lambda: ask("eval", id=hosts[label], js="window.result").get("value"), 30)
        except RuntimeError as error:
            state = ask("eval", id=hosts[label], js="({operation: window.operation, lastCheck: window.lastCheck, ready: document.readyState, url: location.href})")
            raise RuntimeError(f"{label}/{command}: {error}; controller={state}; completed={results}") from error
        after = [(tab["id"], tab["active"]) for tab in ask("tabs")["tabs"]]
        result["checks"].append({"ok": before == after, "message": "native tab row and selection unchanged"})
        if before != after:
            result["errors"].append("native tab row or selection changed")
        result.update(extension=label, operation=command)
        results.append(result)
        return result.get("context")

    def frame_ack(label):
        def received():
            with server.acks_lock:
                return server.acks.get(label)
        try:
            acknowledgement = poll(received, 6)
        except RuntimeError as error:
            acknowledgement = {"error": str(error)}
        ok = acknowledgement.get("received") is True
        message = "iframe content script receives its offscreen parent's asynchronous reply"
        results.append({"extension": label, "operation": "frame-ack", "acknowledgement": acknowledgement,
                        "checks": [{"ok": ok, "message": message}], "errors": [] if ok else [message]})

    try:
        with tempfile.TemporaryDirectory(prefix="search-offscreen-") as folder:
            for label in ("A", "B"):
                directory = Path(folder) / label
                directory.mkdir()
                manifest = {"manifest_version": 3, "name": "Search offscreen regression " + label,
                            "description": "Verify real offscreen documents, messaging, context filters and isolation.",
                            "version": "1.0", "permissions": ["offscreen", "tabs"],
                            "action": {"default_popup": "popup.html"},
                            "host_permissions": ["http://127.0.0.1/*"],
                            "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["content.js"],
                                                 "all_frames": True, "run_at": "document_end"}]}
                if label == "A":
                    manifest["background"] = {"service_worker": "background.js"}
                    (directory / "background.js").write_text(BACKGROUND)
                (directory / "manifest.json").write_text(json.dumps(manifest))
                (directory / "host.html").write_text('<!doctype html><title>Offscreen controller</title><script src="host.js"></script>')
                # A tab at the declared popup URL also gets Search's popup compatibility shim.
                # Keep the controller URL separate from the popup we exercise below.
                (directory / "popup.html").write_text('<!doctype html><title>Offscreen popup</title><script src="host.js"></script>')
                frame_url = origin + "/frame?owner=" + label
                (directory / "host.js").write_text("window.owner = " + json.dumps(label) +
                    "; window.frameURL = " + json.dumps(frame_url) + ";\n" + HOST)
                (directory / "offscreen.html").write_text('<!doctype html><title>Offscreen fixture</title><script src="offscreen.js"></script>')
                constants = "const OWNER = " + json.dumps(label) + "; const FRAME_URL = " + json.dumps(frame_url) + ";\n"
                (directory / "offscreen.js").write_text(constants + DOCUMENT)
                (directory / "content.js").write_text(constants + CONTENT)
                (directory / "pending.html").write_text('<!doctype html><title>Offscreen fixture</title>' +
                    f'<img src="{origin}/pending.svg"><script src="pending.js"></script>')
                (directory / "pending.js").write_text(constants + "window.addEventListener('load', () => {" + DOCUMENT + "});")
                ask("ext-folder", path=str(directory), yes=True)

                def installed():
                    for item in ask("extensions")["extensions"]:
                        if item.get("source") == str(directory):
                            extensions[label] = item["id"]
                            return item["loaded"]
                    return False

                poll(installed)
                open_host(label)
            ask("eval", id=hosts["A"], js="window.beginPending(); true")
            poll(server.started.is_set, 10)  # The real document is loading and cannot finish yet.
            run("A", "cancel-pending")
            server.release.set()
            run("A", "absolute")  # A cancelled create must release its reservation for this retry.
            run("A", "close")
            run("A", "invalid")
            first = run("A", "create")
            run("A", "unanswered")
            run("A", "slow-worker")
            run("A", "iframe")
            frame_ack("A")
            other = run("B", "create")
            run("B", "iframe")
            frame_ack("B")
            run("A", "frame-status")
            run("B", "frame-status")
            ask("eval", id=hosts["B"], js="window.beginDelayed(); true")
            poll(server.delayed_armed.is_set, 5)
            run("B", "cancel-delayed")
            other = run("B", "create", other)
            no_late_work = not server.delayed_fired.wait(2.5)
            message = "closed offscreen document performs no delayed HTTP side effect"
            results.append({"extension": "B", "operation": "closed-document-lifetime",
                            "checks": [{"ok": no_late_work, "message": message}],
                            "errors": [] if no_late_work else [message]})
            run("A", "isolated", first)
            run("A", "close")
            run("B", "isolated", other)
            recreated = run("A", "create", first)
            for lifecycle in ("reload", "disable"):
                ask("close", id=hosts.pop("A"))
                if lifecycle == "reload":
                    ask("ext-reload", id=extensions["A"])
                else:
                    ask("ext-enable", id=extensions["A"], on=False)
                    poll(lambda: not loaded("A"))
                    ask("ext-enable", id=extensions["A"], on=True)
                poll(lambda: loaded("A"))
                open_host("A")
                run("A", "empty")
                recreated = run("A", "create", recreated)
                run("B", "isolated", other)
            run("A", "close")
            run("B", "close")
            ask("ext-press", id=extensions["A"])
            poll(lambda: ask("ext-popup", id=extensions["A"], js="typeof window.run === 'function'").get("value"))
            ask("ext-popup", id=extensions["A"], js="window.discovery = null; chrome.runtime.getContexts({}).then(value => window.discovery = value); true")
            discovery = poll(lambda: ask("ext-popup", id=extensions["A"], js="window.discovery").get("value"))
            types = sorted(item["contextType"] for item in discovery)
            message = "background and popup contexts remain discoverable after offscreen teardown"
            ok = types == ["BACKGROUND", "POPUP"]
            results.append({"extension": "A", "operation": "other-contexts", "contextTypes": types,
                            "checks": [{"ok": ok, "message": message}], "errors": [] if ok else [message]})
        print(json.dumps(results, indent=2))
        return int(any(result["errors"] for result in results))
    except Exception:
        print(json.dumps(results, indent=2), flush=True)
        raise
    finally:
        server.release.set()
        cleanup_errors = []
        for label, extension_id in extensions.items():
            try:
                if label not in hosts and loaded(label):
                    open_host(label)
                if label in hosts:
                    run(label, "close")
            except Exception as error:
                cleanup_errors.append(str(error))
            try:
                if label in hosts:
                    ask("close", id=hosts[label])
            except Exception as error:
                cleanup_errors.append(str(error))
            try:
                ask("ext-remove", id=extension_id)
            except Exception as error:
                cleanup_errors.append(str(error))
        server.shutdown()
        server.server_close()
        if cleanup_errors:
            raise RuntimeError("cleanup failed: " + "; ".join(cleanup_errors))


if __name__ == "__main__":
    raise SystemExit(main())
