// Entire installed shim, including its real content-script early return.
// Used by Node on any platform and JavaScriptCore in the Swift regression.
function recoveryFixture(content, generation = 0) {
  const events = () => {
    const listeners = new Set();
    return { addListener: f => listeners.add(f), removeListener: f => listeners.delete(f),
      hasListener: f => listeners.has(f), hasListeners: () => listeners.size > 0,
      fire: (...args) => [...listeners].forEach(f => f(...args)) };
  };
  const state = { nativePorts: [], cancellations: 0, subscriptions: [], calls: [], timers: [], handlers: {}, now: 100000 };
  const runtime = Object.assign(Object.create({
    sendMessage: message => Promise.resolve(message && message.__searchPing ? 'pong' : undefined)
  }), {
    id: 'fixture', getURL: path => 'webkit-extension://fixture/' + path,
    getManifest: () => ({ background: { service_worker: 'worker.js' } }),
    onMessage: events(), onMessageExternal: events(), onConnect: events(),
    connect: (...args) => {
      const port = { name: 'fixture', onMessage: events(), onDisconnect: events(), posts: [], disconnects: 0,
        postMessage(message) { this.posts.push(message); },
        disconnect() { this.disconnects++; this.nativeDisconnect.fire(this); } };
      port.nativeDisconnect = port.onDisconnect;
      state.nativePorts.push(port);
      return port;
    },
    sendNativeMessage: (application, message) => {
      state.calls.push(message.api);
      if (message.api === 'background.unobserve') state.cancellations++;
      if (message.api === 'background.observe') return subscribe(message.args[0]).then(value => ({ value }));
      return Promise.resolve({ value: false });
    }
  });
  const subscribe = expected => new Promise((resolve, reject) => state.subscriptions.push({ expected, resolve, reject }));
  const root = {
    chrome: { runtime }, location: { protocol: content ? 'https:' : 'webkit-extension:',
      href: content ? 'https://example.test/' : 'webkit-extension://fixture/page.html',
      origin: content ? 'https://example.test' : 'webkit-extension://fixture', pathname: '/' },
    document: {}, navigator: { userAgent: ' Chrome/130' },
    setTimeout: (callback, delay) => { state.timers.push({ callback, delay }); return state.timers.length; },
    clearTimeout: () => {}, addEventListener: (name, callback) => { (state.handlers[name] ||= []).push(callback); },
    Date: class extends Date { static now() { return state.now; } },
    console, __SEARCH_EVENTS__: [], __SEARCH_SCRIPTS__: [], __SEARCH_VERBOSE__: false,
    webkit: { messageHandlers: { searchWorkerRecovery: { postMessage: message => message.cancel ? (state.cancellations++, Promise.resolve()) : subscribe(message.generation) } } }
  };
  root.window = root; root.top = root;
  state.root = root; state.runtime = runtime; state.makePort = runtime.connect; state.initialGeneration = generation;
  return state;
}
