// DevTools' WebAudio tool (DeveloperWebAudio.swift): while it is open, the
// page's audio contexts and the graph of nodes in each are reported as the
// page builds them. Runs in the page's world, at document start in every
// frame and once in the page already up, called with the capture's token.
// Contexts are seen as they're constructed, nodes as a context's create…
// methods make them or as they connect, and every connect and disconnect,
// to a node or to an AudioParam, as it happens.
((session) => {
    "use strict";
    const handler = globalThis.webkit?.messageHandlers?.perchWebAudio;
    if (!handler)
        return false;
    // The capture's state stays off the page's enumerable globals. The
    // cleanup script finds it by this key and asks whether it's its own.
    const key = Symbol.for("perch.webAudioCapture");
    const prior = globalThis[key];
    if (prior?.owns?.(session))
        return true;
    // An earlier session's capture goes first, so this one wraps the
    // engine's own constructors and methods rather than that capture's.
    prior?.stop?.();

    const AudioNodeClass = globalThis.AudioNode;
    const AudioParamClass = globalThis.AudioParam;
    const RealtimeClass = globalThis.AudioContext ?? globalThis.webkitAudioContext;
    const BaseClass = globalThis.BaseAudioContext ?? RealtimeClass;
    const OfflineClass = globalThis.OfflineAudioContext ?? globalThis.webkitOfflineAudioContext;
    if (typeof AudioNodeClass !== "function" || typeof AudioParamClass !== "function" || typeof BaseClass !== "function")
        return false;

    // Taken now, so a page that replaces these later can't skew or stop
    // the capture.
    const post = handler.postMessage;
    const schedule = globalThis.setTimeout;
    const repeat = globalThis.setInterval;
    const unrepeat = globalThis.clearInterval;
    const unschedule = globalThis.clearTimeout;
    const listen = globalThis.EventTarget?.prototype?.addEventListener;
    const Controller = globalThis.AbortController;
    const Ref = globalThis.WeakRef;
    const finite = Number.isFinite;
    const isPrototype = Object.prototype.isPrototypeOf;
    const describe = Object.getOwnPropertyDescriptor;
    const define = Object.defineProperty;
    const names = Object.getOwnPropertyNames;
    const prototypeOf = Object.getPrototypeOf;
    if (typeof post !== "function" || typeof schedule !== "function" || typeof unschedule !== "function"
        || typeof repeat !== "function" || typeof unrepeat !== "function")
        return false;

    const getter = (prototype, name) => {
        for (let level = prototype; level; level = prototypeOf(level)) {
            const descriptor = describe(level, name);
            if (descriptor)
                return typeof descriptor.get === "function" ? descriptor.get : null;
        }
        return null;
    };
    const read = (get, object) => {
        if (!get || object === null || object === undefined)
            return undefined;
        try { return Reflect.apply(get, object, []); } catch { return undefined; }
    };
    const isA = (prototype, value) => value !== null && typeof value === "object" && !!prototype
        && Reflect.apply(isPrototype, prototype, [value]);
    const number = (value) => typeof value === "number" && finite(value) ? value : null;
    const text = (value) => typeof value === "string" ? value.slice(0, 64) : "";
    const index = (value) => typeof value === "number" && finite(value) && value >= 0 ? value >>> 0 : 0;
    const weak = (value) => typeof Ref === "function" ? new Ref(value) : {deref: () => value};

    const get = {
        state: getter(BaseClass.prototype, "state"),
        sampleRate: getter(BaseClass.prototype, "sampleRate"),
        currentTime: getter(BaseClass.prototype, "currentTime"),
        destination: getter(BaseClass.prototype, "destination"),
        baseLatency: getter(RealtimeClass?.prototype, "baseLatency"),
        outputLatency: getter(RealtimeClass?.prototype, "outputLatency"),
        maxChannelCount: getter(globalThis.AudioDestinationNode?.prototype, "maxChannelCount"),
        context: getter(AudioNodeClass.prototype, "context"),
        channelCount: getter(AudioNodeClass.prototype, "channelCount"),
        channelCountMode: getter(AudioNodeClass.prototype, "channelCountMode"),
        channelInterpretation: getter(AudioNodeClass.prototype, "channelInterpretation"),
        inputs: getter(AudioNodeClass.prototype, "numberOfInputs"),
        outputs: getter(AudioNodeClass.prototype, "numberOfOutputs"),
        value: getter(AudioParamClass.prototype, "value"),
        defaultValue: getter(AudioParamClass.prototype, "defaultValue"),
        minValue: getter(AudioParamClass.prototype, "minValue"),
        maxValue: getter(AudioParamClass.prototype, "maxValue"),
        automationRate: getter(AudioParamClass.prototype, "automationRate"),
    };

    // Each node's type by its interface, read from the window's own
    // interface objects (their descriptors, so no page getter runs).
    const kinds = new Map;
    for (const name of names(globalThis)) {
        if (!name.endsWith("Node"))
            continue;
        const value = describe(globalThis, name)?.value;
        if (typeof value !== "function" || !value.prototype)
            continue;
        if (value !== AudioNodeClass && !isA(AudioNodeClass.prototype, value.prototype))
            continue;
        const known = kinds.get(value.prototype);
        if (!known || known.startsWith("webkit"))
            kinds.set(value.prototype, name);
    }
    const kindOf = (node) => {
        for (let level = prototypeOf(node); level; level = prototypeOf(level)) {
            const name = kinds.get(level);
            if (name)
                return name;
        }
        return "AudioNode";
    };

    // A node's AudioParams: its interface's getters that return one.
    const paramGetters = new Map;
    const paramsOf = (node) => {
        const prototype = prototypeOf(node);
        let found = paramGetters.get(prototype);
        if (found)
            return found;
        found = [];
        const seen = new Set;
        for (let level = prototype; level && level !== AudioNodeClass.prototype; level = prototypeOf(level)) {
            for (const name of names(level)) {
                const descriptor = describe(level, name);
                if (seen.has(name) || typeof descriptor?.get !== "function")
                    continue;
                seen.add(name);
                if (isA(AudioParamClass.prototype, read(descriptor.get, node)))
                    found.push({name, read: descriptor.get});
            }
        }
        paramGetters.set(prototype, found);
        return found;
    };

    const frame = Math.random().toString(36).slice(2);
    const listeners = typeof Controller === "function" ? new Controller : null;
    const contextRecords = new WeakMap;
    const nodeIDs = new WeakMap;
    const paramOwners = new WeakMap;
    const contexts = [];
    let sequence = 0;
    let pending = [];
    let lost = 0;
    let timer = 0;
    let ticker = 0;
    let active = true;

    function send(events, dropped) {
        try { Reflect.apply(post, handler, [{session, frame, events, dropped}]); } catch {}
    }

    function flush() {
        timer = 0;
        const events = pending, dropped = lost;
        pending = [];
        lost = 0;
        if (active && (events.length || dropped))
            send(events, dropped);
    }

    function emit(event) {
        if (!active)
            return;
        if (pending.length < 1024)
            pending.push(event);
        else
            lost++;
        if (!timer)
            timer = Reflect.apply(schedule, globalThis, [flush, 16]);
    }

    function describeContext(record) {
        const context = record.ref.deref();
        if (!context)
            return;
        const event = {
            kind: "context",
            id: record.id,
            type: isA(OfflineClass?.prototype, context) ? "offline" : "realtime",
            state: text(read(get.state, context)),
            sampleRate: number(read(get.sampleRate, context)),
            currentTime: number(read(get.currentTime, context)),
            baseLatency: number(read(get.baseLatency, context)),
            outputLatency: number(read(get.outputLatency, context)),
            maxChannelCount: number(read(get.maxChannelCount, read(get.destination, context))),
        };
        const signature = event.state + "|" + event.currentTime;
        if (signature === record.last)
            return;
        record.last = signature;
        emit(event);
    }

    // Once a second while there are contexts: their state and clock, and
    // the contexts and nodes the page let go of.
    function tick() {
        for (let i = contexts.length - 1; i >= 0; i--) {
            const record = contexts[i];
            if (!record.ref.deref()) {
                contexts.splice(i, 1);
                emit({kind: "contextGone", id: record.id});
                continue;
            }
            describeContext(record);
            for (let n = record.nodes.length - 1; n >= 0; n--) {
                if (record.nodes[n].ref.deref()) {
                    describeParams(record.nodes[n]);
                    continue;
                }
                emit({kind: "nodeGone", id: record.nodes[n].id});
                record.nodes.splice(n, 1);
            }
        }
        if (!contexts.length && ticker) {
            Reflect.apply(unrepeat, globalThis, [ticker]);
            ticker = 0;
        }
    }

    // A node's parameter values as they are now (gain.value set after the
    // node was made, an automation running), sent when they change.
    function describeParams(entry) {
        if (!entry.params?.length)
            return;
        const values = {};
        for (const param of entry.params) {
            const target = param.ref.deref();
            if (target)
                values[param.name] = number(read(get.value, target));
        }
        const signature = JSON.stringify(values);
        if (signature === entry.last)
            return;
        entry.last = signature;
        emit({kind: "params", id: entry.id, values});
    }

    function contextRecord(context) {
        if (!isA(BaseClass.prototype, context))
            return null;
        let record = contextRecords.get(context);
        if (record)
            return record;
        if (contexts.length >= 64)
            return null;
        record = {id: frame + "-c" + ++sequence, ref: weak(context), nodes: [], last: ""};
        contextRecords.set(context, record);
        contexts.push(record);
        if (typeof listen === "function" && listeners) {
            const update = () => { if (active) describeContext(record); };
            try { Reflect.apply(listen, context, ["statechange", update, {signal: listeners.signal}]); } catch {}
        }
        describeContext(record);
        const destination = read(get.destination, context);
        if (destination)
            nodeID(destination);
        if (!ticker)
            ticker = Reflect.apply(repeat, globalThis, [tick, 1000]);
        return record;
    }

    function nodeID(node) {
        if (!isA(AudioNodeClass.prototype, node))
            return null;
        const known = nodeIDs.get(node);
        if (known)
            return known;
        const record = contextRecord(read(get.context, node));
        if (!record || record.nodes.length >= 2000)
            return null;
        const id = frame + "-n" + ++sequence;
        nodeIDs.set(node, id);
        const entry = {id, ref: weak(node), params: [], last: ""};
        record.nodes.push(entry);
        const params = [];
        for (const param of paramsOf(node)) {
            const value = read(param.read, node);
            if (!isA(AudioParamClass.prototype, value))
                continue;
            paramOwners.set(value, {node: id, name: param.name});
            if (entry.params.length < 64)
                entry.params.push({name: param.name, ref: weak(value)});
            params.push({
                name: param.name,
                value: number(read(get.value, value)),
                defaultValue: number(read(get.defaultValue, value)),
                minValue: number(read(get.minValue, value)),
                maxValue: number(read(get.maxValue, value)),
                rate: text(read(get.automationRate, value)),
            });
        }
        // The values sent with the node are the ones a change is noticed against.
        const sent = {};
        for (const param of params)
            sent[param.name] = param.value;
        entry.last = JSON.stringify(sent);
        emit({
            kind: "node",
            context: record.id,
            id,
            type: kindOf(node),
            channelCount: number(read(get.channelCount, node)),
            channelCountMode: text(read(get.channelCountMode, node)),
            channelInterpretation: text(read(get.channelInterpretation, node)),
            inputs: number(read(get.inputs, node)),
            outputs: number(read(get.outputs, node)),
            params,
        });
        return id;
    }

    function connected(source, args) {
        const sourceID = nodeID(source);
        if (!sourceID)
            return;
        const target = args[0];
        const output = args.length > 1 ? index(args[1]) : 0;
        if (isA(AudioParamClass.prototype, target)) {
            const owner = paramOwners.get(target);
            if (owner)
                emit({kind: "connect", source: sourceID, output, destination: owner.node, input: 0, param: owner.name});
            return;
        }
        const destinationID = nodeID(target);
        if (destinationID)
            emit({kind: "connect", source: sourceID, output, destination: destinationID, input: args.length > 2 ? index(args[2]) : 0});
    }

    function disconnected(source, args) {
        const sourceID = nodeIDs.get(source);
        if (!sourceID)
            return;
        if (!args.length)
            return emit({kind: "disconnect", source: sourceID});
        const target = args[0];
        if (typeof target === "number")
            return emit({kind: "disconnect", source: sourceID, output: index(target)});
        const output = args.length > 1 ? index(args[1]) : null;
        if (isA(AudioParamClass.prototype, target)) {
            const owner = paramOwners.get(target);
            if (owner)
                emit({kind: "disconnect", source: sourceID, destination: owner.node, output, param: owner.name});
            return;
        }
        const destinationID = nodeIDs.get(target);
        if (destinationID)
            emit({kind: "disconnect", source: sourceID, destination: destinationID, output, input: args.length > 2 ? index(args[2]) : null});
    }

    // Everything replaced, to put back as it was when the capture stops.
    const replaced = [];
    const replace = (target, name, descriptor, value) => {
        try {
            define(target, name, {...descriptor, value});
            replaced.push({target, name, descriptor, value});
        } catch {}
    };

    // A proxy of each native function keeps its name, length and source text.
    const watchCall = (native, after) => new Proxy(native, {
        apply(target, self, args) {
            const result = Reflect.apply(target, self, args);
            if (active) {
                try { after(self, args, result); } catch {}
            }
            return result;
        },
    });

    for (const name of ["connect", "disconnect"]) {
        const descriptor = describe(AudioNodeClass.prototype, name);
        if (typeof descriptor?.value !== "function" || !descriptor.configurable)
            continue;
        replace(AudioNodeClass.prototype, name, descriptor,
            watchCall(descriptor.value, name === "connect" ? connected : disconnected));
    }

    const madeNode = (self, args, result) => { nodeID(result); };
    const prototypes = new Set;
    for (const constructor of [BaseClass, RealtimeClass, OfflineClass, globalThis.webkitAudioContext, globalThis.webkitOfflineAudioContext]) {
        const prototype = typeof constructor === "function" ? constructor.prototype : null;
        if (!prototype || prototypes.has(prototype))
            continue;
        prototypes.add(prototype);
        for (const name of names(prototype)) {
            if (!name.startsWith("create"))
                continue;
            const descriptor = describe(prototype, name);
            if (typeof descriptor?.value === "function" && descriptor.configurable)
                replace(prototype, name, descriptor, watchCall(descriptor.value, madeNode));
        }
    }

    const wrappers = new Map;
    for (const name of ["AudioContext", "OfflineAudioContext", "webkitAudioContext", "webkitOfflineAudioContext"]) {
        const descriptor = describe(globalThis, name);
        const native = descriptor?.value;
        if (typeof native !== "function" || !(descriptor.writable || descriptor.configurable))
            continue;
        let wrapper = wrappers.get(native);
        if (!wrapper) {
            wrapper = new Proxy(native, {
                construct(target, args, newTarget) {
                    const context = Reflect.construct(target, args, newTarget);
                    if (active) {
                        try { contextRecord(context); } catch {}
                    }
                    return context;
                },
            });
            wrappers.set(native, wrapper);
            // AudioContext.prototype.constructor is AudioContext, as without Perch.
            const own = native.prototype ? describe(native.prototype, "constructor") : undefined;
            if (own?.value === native && own.configurable)
                replace(native.prototype, "constructor", own, wrapper);
        }
        if (descriptor.configurable) {
            replace(globalThis, name, descriptor, wrapper);
        } else {
            try {
                globalThis[name] = wrapper;
                if (globalThis[name] === wrapper)
                    replaced.push({target: globalThis, name, descriptor, value: wrapper, assigned: true});
            } catch {}
        }
    }

    const state = Object.freeze({
        owns: (other) => other === session,
        stop() {
            active = false;
            Reflect.apply(unschedule, globalThis, [timer]);
            timer = 0;
            if (ticker)
                Reflect.apply(unrepeat, globalThis, [ticker]);
            ticker = 0;
            pending = [];
            contexts.length = 0;
            listeners?.abort();
            for (let i = replaced.length - 1; i >= 0; i--) {
                const entry = replaced[i];
                try {
                    if (entry.assigned) {
                        if (entry.target[entry.name] === entry.value)
                            entry.target[entry.name] = entry.descriptor.value;
                    } else if (describe(entry.target, entry.name)?.value === entry.value) {
                        define(entry.target, entry.name, entry.descriptor);
                    }
                } catch {}
            }
            replaced.length = 0;
            if (globalThis[key] === state)
                delete globalThis[key];
        },
    });
    try {
        define(globalThis, key, {value: state, configurable: true, enumerable: false, writable: false});
    } catch {}
    // Register the frame, so the capture is taken out of it when DevTools closes.
    send([], 0);
    return true;
})
