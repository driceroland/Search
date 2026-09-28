import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

// Run with: node Tests/ExtensionRelayKey/relay-key.test.mjs
// Evaluate the production helper itself, sliced from the shim source, so the
// regression covers the same key function used to pair native and relayed messages.
const shimURL = new URL("../../Sources/Search/ExtensionShims.swift", import.meta.url);
const source = readFileSync(fileURLToPath(shimURL), "utf8");

function sourceBetween(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  assert.notEqual(start, -1, `missing source marker: ${startMarker}`);
  const end = source.indexOf(endMarker, start);
  assert.notEqual(end, -1, `missing source marker: ${endMarker}`);
  return source.slice(start, end);
}

const relayContext = vm.createContext({});
const relaySource = sourceBetween("const relayKey = (message) => {", "const ownPlace =");
vm.runInContext(`${relaySource}\nthis.relayKey = relayKey;`, relayContext);
const relayKey = (expression) => vm.runInContext(`relayKey(${expression})`, relayContext);

const nativeCopy = relayKey(`({command:"PickCredentialRequest",type:"credential",sessionId:"s-1",
  cipherIds:["a","b"],userVerification:true,fallbackSupported:false,
  nested:{challenge:{rpId:"example.test",timeout:30000},extensions:{prf:true}}})`);
const relayedCopy = relayKey(`({nested:{extensions:{prf:true},challenge:{timeout:30000,rpId:"example.test"}},
  fallbackSupported:false,userVerification:true,cipherIds:["a","b"],sessionId:"s-1",
  type:"credential",command:"PickCredentialRequest"})`);
assert.equal(nativeCopy, relayedCopy, "nested object insertion order must not split a matching pair");

const longA = relayKey(`({payload:"x".repeat(5000),suffix:"a"})`);
const longB = relayKey(`({payload:"x".repeat(5000),suffix:"b"})`);
assert.ok(longA.length > 4000, "the complete payload remains in the key");
assert.notEqual(longA, longB, "differences after the first 4000 characters must remain distinct");
assert.notEqual(relayKey(`({ids:["a","b"]})`), relayKey(`({ids:["b","a"]})`), "array order remains significant");
assert.notEqual(relayKey(`({value:1})`), relayKey(`({value:"1"})`), "numbers and strings remain distinct");
assert.notEqual(relayKey(`({value:true})`), relayKey(`({value:1})`), "booleans and numbers remain distinct");
assert.notEqual(
  relayKey(`JSON.parse('{"__proto__":{"marked":true},"value":1}')`),
  relayKey(`JSON.parse('{"value":1}')`),
  "an own __proto__ key must be retained during sorting",
);

assert.equal(relayKey("undefined"), null, "undefined at the top level has no JSON representation");
assert.equal(relayKey("({missing:undefined})"), relayKey("({})"), "undefined object fields follow JSON.stringify omission");
assert.equal(relayKey("([undefined])"), relayKey("([null])"), "undefined array entries follow JSON.stringify null conversion");
assert.equal(
  relayKey(`({when:new Date("2026-09-28T00:00:00.000Z")})`),
  relayKey(`({when:"2026-09-28T00:00:00.000Z"})`),
  "Date values keep JSON's toJSON representation",
);
assert.equal(relayKey("(()=>{const value={};value.self=value;return value})()"), null,
  "cyclic messages safely have no relay key");

const senderContext = vm.createContext({});
const senderSource = sourceBetween("const ownPlace =", "const heardNatively");
vm.runInContext(`const runtime={id:"fixture",getURL:()=>"chrome-extension://fixture/"};\n${senderSource}\nthis.fromOwnPages=fromOwnPages;`, senderContext);
const fromOwnPages = (sender) => {
  senderContext.sender = sender;
  return vm.runInContext("fromOwnPages(sender)", senderContext);
};
assert.equal(fromOwnPages({ id: "fixture", url: "chrome-extension://fixture/page.html" }), true,
  "a page from this extension can pair a native copy");
assert.equal(fromOwnPages({ id: "fixture", url: "https://site.example/page", tab: { id: 4 } }), false,
  "a content script remains outside the extension-page pairing set");
assert.equal(fromOwnPages({ id: "other", url: "chrome-extension://fixture/page.html" }), false,
  "another extension cannot pair a native copy");
assert.equal(fromOwnPages(null), false);

console.log("Extension relay key regression passed (canonical JSON, full payloads, JSON edge cases, sender filtering).");
