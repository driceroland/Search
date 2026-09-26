// Run from the repository root with: swift Tests/ExtensionShimsSymbolDispose.swift
import Foundation
import JavaScriptCore

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

final class Runtime {
    let js: JSContext
    private(set) var exception: String?

    init(_ machine: JSVirtualMachine) {
        js = JSContext(virtualMachine: machine)!
        js.exceptionHandler = { [weak self] _, value in self?.exception = value?.toString() }
    }

    func evaluate(_ source: String) throws -> JSValue {
        exception = nil
        js.exception = nil
        guard let value = js.evaluateScript(source) else { throw TestFailure(description: "JavaScript returned no value") }
        if let exception { throw TestFailure(description: "JavaScript exception: \(exception)") }
        return value
    }
}

func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(description: message) }
}

func extensionShim(from repository: URL) throws -> String {
    let source = try String(contentsOf: repository.appendingPathComponent("Sources/Search/ExtensionShims.swift"), encoding: .utf8)
    guard let start = source.range(of: "nonisolated static let script = #\"\"\""),
          let end = source.range(of: "\"\"\"#", range: start.upperBound..<source.endIndex) else {
        throw TestFailure(description: "Could not find the extension shim's raw JavaScript in ExtensionShims.swift")
    }
    return String(source[start.upperBound..<end.lowerBound])
        .replacingOccurrences(of: "__SEARCH_EVENTS__", with: "[]")
        .replacingOccurrences(of: "__SEARCH_SCRIPTS__", with: "[]")
        .replacingOccurrences(of: "__SEARCH_CHROME__", with: "140.0.0.0")
        .replacingOccurrences(of: "__SEARCH_VERBOSE__", with: "false")
}

let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let shim = try extensionShim(from: repository)
let machine = JSVirtualMachine()!

func makeRuntime(extensionRealm: Bool, machine: JSVirtualMachine) throws -> Runtime {
    let runtime = Runtime(machine)
    if extensionRealm {
        _ = try runtime.evaluate("""
        globalThis.chrome = { runtime: { id: "symbol-dispose-test" } };
        globalThis.navigator = { userAgent: "Mozilla/5.0 Safari/605.1.15" };
        "ready";
        """)
    }
    return runtime
}

let extensionPage = try makeRuntime(extensionRealm: true, machine: machine)
let disposeMissingAtStart = try extensionPage.evaluate("Symbol.dispose === undefined").toBool()
let asyncDisposeMissingAtStart = try extensionPage.evaluate("Symbol.asyncDispose === undefined").toBool()
let symbolsMissingAtStart = disposeMissingAtStart && asyncDisposeMissingAtStart

_ = try extensionPage.evaluate(#"""
var __addDisposableResource = (env, value, async) => {
  if (value !== null && value !== void 0) {
    if (typeof value !== "object" && typeof value !== "function") throw new TypeError("Object expected.");
    var dispose, syncDispose;
    if (async) {
      if (!Symbol.asyncDispose) throw new TypeError("Symbol.asyncDispose is not defined.");
      dispose = value[Symbol.asyncDispose];
    }
    if (dispose === void 0) {
      if (!Symbol.dispose) throw new TypeError("Symbol.dispose is not defined.");
      dispose = value[Symbol.dispose];
      if (async) syncDispose = dispose;
    }
    if (typeof dispose !== "function") throw new TypeError("Object not disposable.");
    if (syncDispose) dispose = function () { try { syncDispose.call(this); } catch (error) { return Promise.reject(error); } };
    env.stack.push({ value: value, dispose: dispose, async: async });
  } else if (async) env.stack.push({ async: true });
  return value;
};
var __disposeResources = (env) => {
  var Suppressed = typeof SuppressedError === "function" ? SuppressedError : function (error, suppressed, message) {
    var result = new Error(message); result.name = "SuppressedError"; result.error = error; result.suppressed = suppressed; return result;
  };
  function fail(error) {
    env.error = env.hasError ? new Suppressed(error, env.error, "An error was suppressed during disposal.") : error;
    env.hasError = true;
  }
  var record, state = 0;
  function next() {
    while ((record = env.stack.pop())) {
      try {
        if (!record.async && state === 1) { state = 0; env.stack.push(record); return Promise.resolve().then(next); }
        if (record.dispose) {
          var result = record.dispose.call(record.value);
          if (record.async) { state |= 2; return Promise.resolve(result).then(next, (error) => { fail(error); return next(); }); }
        } else state |= 1;
      } catch (error) { fail(error); }
    }
    if (state === 1) return env.hasError ? Promise.reject(env.error) : Promise.resolve();
    if (env.hasError) throw env.error;
  }
  return next();
};
var BeforeShim = class { [Symbol.dispose]() { this.cleaned = true; } };
"""#)

if disposeMissingAtStart {
    let beforeShimError = try extensionPage.evaluate("""
    try { __addDisposableResource({ stack: [] }, new BeforeShim(), false); "no error"; }
    catch (error) { error.message; }
    """).toString()
    try expect(beforeShimError == "Symbol.dispose is not defined.", "The TypeScript helper should reproduce Bitwarden's pre-shim Symbol.dispose error")
}

_ = try extensionPage.evaluate(shim)
try expect(try extensionPage.evaluate("globalThis.__searchShim === true").toBool(), "The real extension shim should complete its bootstrap")

if disposeMissingAtStart {
    let tooLate = try extensionPage.evaluate("""
    try { __addDisposableResource({ stack: [] }, new BeforeShim(), false); "no error"; }
    catch (error) { error.message; }
    """).toString()
    try expect(tooLate == "Object not disposable.", "Adding Symbol.dispose after a computed class key was made must not repair that class")
}

let cleanup = try extensionPage.evaluate("""
(() => {
  let syncReleased = false, asyncCleaned = false;
  class BitwardenReference {
    constructor(release, value) { this.release = release; this.value = value; }
    [Symbol.dispose]() { this.release(); }
  }
  class AsyncResource { [Symbol.asyncDispose]() { return Promise.resolve().then(() => { asyncCleaned = true; }); } }
  const syncEnv = { stack: [] }, asyncEnv = { stack: [] };
  __addDisposableResource(syncEnv, new BitwardenReference(() => { syncReleased = true; }, "secret"), false);
  __disposeResources(syncEnv);
  __addDisposableResource(asyncEnv, new AsyncResource(), true);
  globalThis.__disposeTest = { syncReleased, asyncCleaned: false, complete: false };
  return __disposeResources(asyncEnv).then(() => {
    globalThis.__disposeTest = { syncReleased, asyncCleaned, complete: true };
  });
})()
""")
_ = cleanup
for _ in 0..<20 {
    if try extensionPage.evaluate("globalThis.__disposeTest && __disposeTest.complete === true").toBool() { break }
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}
try expect(try extensionPage.evaluate("__disposeTest.syncReleased && __disposeTest.asyncCleaned && __disposeTest.complete").toBool(), "The TypeScript disposal helpers should complete sync and async cleanup")

let shimmedNames = [disposeMissingAtStart ? "dispose" : nil, asyncDisposeMissingAtStart ? "asyncDispose" : nil].compactMap { $0 }
let shimmedNamesJSON = String(data: try JSONSerialization.data(withJSONObject: shimmedNames), encoding: .utf8)!
try expect(try extensionPage.evaluate("""
\(shimmedNamesJSON).every((name) => {
  const symbol = Symbol[name], descriptor = Object.getOwnPropertyDescriptor(Symbol, name);
  return symbol === Symbol.for("Symbol." + name) && symbol.description === "Symbol." + name &&
    descriptor && descriptor.writable === false && descriptor.enumerable === false && descriptor.configurable === false;
})
""").toBool(), "Symbols supplied by the shim should use the shared registry and immutable, non-enumerable properties")

let disposalBeforeRepeat = try extensionPage.evaluate("Symbol.dispose")
_ = try extensionPage.evaluate(shim)
let disposalAfterRepeat = try extensionPage.evaluate("Symbol.dispose")
try expect(disposalBeforeRepeat.isEqual(to: disposalAfterRepeat), "A repeated bootstrap must leave the installed symbol intact")

let secondFrame = try makeRuntime(extensionRealm: true, machine: machine)
_ = try secondFrame.evaluate(shim)
let frameDisposal = try secondFrame.evaluate("Symbol.dispose")
try expect(disposalBeforeRepeat.isEqual(to: frameDisposal), "Extension frames on one JavaScriptCore machine should share the Symbol.dispose key")
let frameAsyncDisposal = try secondFrame.evaluate("Symbol.asyncDispose")
let firstFrameAsyncDisposal = try extensionPage.evaluate("Symbol.asyncDispose")
try expect(firstFrameAsyncDisposal.isEqual(to: frameAsyncDisposal), "Extension frames on one JavaScriptCore machine should share the Symbol.asyncDispose key")

let webPage = try makeRuntime(extensionRealm: false, machine: machine)
let pageSymbolsBefore = try webPage.evaluate("JSON.stringify([typeof Symbol.dispose, typeof Symbol.asyncDispose])").toString()
_ = try webPage.evaluate(shim)
let pageSymbolsAfter = try webPage.evaluate("JSON.stringify([typeof Symbol.dispose, typeof Symbol.asyncDispose])").toString()
try expect(pageSymbolsBefore == pageSymbolsAfter, "A web page without extension APIs must not receive the extension-only symbols")
try expect(try webPage.evaluate("globalThis.__searchShim === undefined").toBool(), "A web page must not receive the extension shim marker")

let nativeContext = try makeRuntime(extensionRealm: true, machine: machine)
_ = try nativeContext.evaluate("""
if (Symbol.dispose === undefined) Object.defineProperty(Symbol, "dispose", { value: Symbol("native dispose") });
if (Symbol.asyncDispose === undefined) Object.defineProperty(Symbol, "asyncDispose", { value: Symbol("native async dispose") });
globalThis.__nativeSymbols = [Symbol.dispose, Symbol.asyncDispose];
"ready";
""")
_ = try nativeContext.evaluate(shim)
try expect(try nativeContext.evaluate("Symbol.dispose === __nativeSymbols[0] && Symbol.asyncDispose === __nativeSymbols[1]").toBool(), "The shim must preserve symbols supplied by JavaScriptCore")

print("Extension Symbol.dispose shim regression checks passed" + (symbolsMissingAtStart ? " (JavaScriptCore lacked both symbols at startup)" : " (native symbols were preserved)"))
