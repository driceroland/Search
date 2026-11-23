// DevTools' WebAuthn tool: while its virtual authenticator environment is
// on, navigator.credentials.create() and get() with a publicKey option are
// answered by Perch's virtual authenticators (DeveloperWebAuthn.swift)
// instead of the system. Runs in the page's world, at document start.
(() => {
    "use strict";
    const handler = window.webkit?.messageHandlers?.perchWebAuthn;
    const container = navigator.credentials;
    if (!handler || !container || !window.isSecureContext || container.__perchWebAuthn)
        return;

    const encode = (value) => {
        let bytes;
        if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
        else if (ArrayBuffer.isView(value)) bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
        else return undefined;
        let text = "";
        for (const byte of bytes) text += String.fromCharCode(byte);
        return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    };
    const decode = (text) => {
        const base64 = text.replace(/-/g, "+").replace(/_/g, "/");
        const binary = atob(base64 + "===".slice((base64.length + 3) % 4));
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return bytes.buffer;
    };
    const descriptors = (list) => Array.isArray(list)
        ? list.map((item) => ({type: item.type, id: encode(item.id), transports: item.transports})) : undefined;
    const value = (target, name, v) => Object.defineProperty(target, name, {value: v, enumerable: true, configurable: true});
    const method = (target, name, f) => Object.defineProperty(target, name, {value: f, configurable: true});

    function credential(reply, kind) {
        const responseClass = kind === "create" ? window.AuthenticatorAttestationResponse : window.AuthenticatorAssertionResponse;
        const response = Object.create(responseClass?.prototype ?? Object.prototype);
        value(response, "clientDataJSON", decode(reply.clientDataJSON));
        if (kind === "create") {
            value(response, "attestationObject", decode(reply.attestationObject));
            method(response, "getAuthenticatorData", () => decode(reply.authenticatorData));
            method(response, "getPublicKey", () => decode(reply.publicKey));
            method(response, "getPublicKeyAlgorithm", () => reply.publicKeyAlgorithm);
            method(response, "getTransports", () => reply.transports.slice());
        } else {
            value(response, "authenticatorData", decode(reply.authenticatorData));
            value(response, "signature", decode(reply.signature));
            value(response, "userHandle", reply.userHandle ? decode(reply.userHandle) : null);
        }
        const result = Object.create(window.PublicKeyCredential?.prototype ?? Object.prototype);
        value(result, "id", reply.id);
        value(result, "rawId", decode(reply.rawId));
        value(result, "type", "public-key");
        value(result, "response", response);
        value(result, "authenticatorAttachment", reply.attachment);
        method(result, "getClientExtensionResults", () => ({}));
        method(result, "toJSON", () => {
            const json = {id: reply.id, rawId: reply.rawId, type: "public-key", authenticatorAttachment: reply.attachment,
                          clientExtensionResults: {}, response: {clientDataJSON: reply.clientDataJSON}};
            if (kind === "create") Object.assign(json.response, {attestationObject: reply.attestationObject,
                authenticatorData: reply.authenticatorData, publicKey: reply.publicKey,
                publicKeyAlgorithm: reply.publicKeyAlgorithm, transports: reply.transports});
            else Object.assign(json.response, {authenticatorData: reply.authenticatorData, signature: reply.signature,
                userHandle: reply.userHandle ?? null});
            return json;
        });
        return result;
    }

    async function ask(kind, publicKey, signal) {
        if (signal?.aborted) throw signal.reason ?? new DOMException("The operation was aborted.", "AbortError");
        const request = {...publicKey, challenge: encode(publicKey.challenge)};
        if (kind === "create") {
            request.user = {...publicKey.user, id: encode(publicKey.user?.id)};
            request.excludeCredentials = descriptors(publicKey.excludeCredentials);
        } else {
            request.allowCredentials = descriptors(publicKey.allowCredentials);
        }
        delete request.extensions;
        const reply = await handler.postMessage({kind, request: JSON.parse(JSON.stringify(request))});
        if (!reply || reply.error) {
            const name = reply?.error ?? "NotAllowedError";
            const message = reply?.message ?? "The virtual authenticator refused the request.";
            throw name === "TypeError" ? new TypeError(message) : new DOMException(message, name);
        }
        return credential(reply, kind);
    }

    const create = container.create.bind(container);
    const get = container.get.bind(container);
    method(container, "__perchWebAuthn", true);
    method(container, "create", function (options) {
        return options?.publicKey ? ask("create", options.publicKey, options.signal) : create(options);
    });
    method(container, "get", function (options) {
        return options?.publicKey ? ask("get", options.publicKey, options.signal) : get(options);
    });
    if (window.PublicKeyCredential) {
        method(PublicKeyCredential, "isUserVerifyingPlatformAuthenticatorAvailable",
               () => handler.postMessage({kind: "platform"}).then((reply) => !!reply?.available));
        method(PublicKeyCredential, "isConditionalMediationAvailable", () => Promise.resolve(false));
    }
})();
