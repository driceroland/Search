function (input) {
  if (window.top !== window || window.location.origin !== new URL(input.origin).origin) return false;
  const key = Symbol.for(input.key);
  if (window[key]) {
    window[key].apply(input);
    return true;
  }

  let position = null, orientation = null, geo = null;
  let original, clearNativeWatch, orientationTimer;
  let nextWatch = 2147483647, firstWatch = nextWatch;
  const watches = new Map(), pending = new Set();

  function send(success, error, watch) {
    const timer = setTimeout(() => {
      pending.delete(timer);
      if (!position || (watch !== undefined && !watches.has(watch))) return;
      if (position.unavailable) {
        if (typeof error === "function") {
          error({code: 2, message: "Simulated location is unavailable",
                 PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3});
        }
      } else {
        const {latitude, longitude, accuracy} = position;
        success({coords: {latitude, longitude, accuracy, altitude: null,
                          altitudeAccuracy: null, heading: null, speed: null}, timestamp: Date.now()});
      }
    }, 0);
    pending.add(timer);
  }

  const methods = {
    getCurrentPosition(success, error) {
      if (typeof success !== "function") throw new TypeError("Expected a position callback");
      if (position) send(success, error);
    },
    watchPosition(success, error) {
      if (typeof success !== "function") throw new TypeError("Expected a position callback");
      const id = nextWatch--;
      if (position) {
        watches.set(id, [success, error]);
        send(success, error, id);
      }
      return id;
    },
    clearWatch(id) {
      if (id > nextWatch && id <= firstWatch) watches.delete(Number(id));
      else clearNativeWatch(id);
    },
  };

  function installLocation() {
    geo = navigator.geolocation;
    if (!geo) throw new Error("Geolocation is unavailable on this page");
    clearNativeWatch = geo.clearWatch.bind(geo);
    original = new Map(Object.keys(methods).map(name => [name, Object.getOwnPropertyDescriptor(geo, name)]));
    for (const [name, method] of Object.entries(methods)) {
      Object.defineProperty(geo, name, {configurable: true, writable: true, value: method});
    }
  }

  function restoreLocation() {
    position = null;
    for (const timer of pending) clearTimeout(timer);
    pending.clear();
    watches.clear();
    for (const [name, descriptor] of original || []) {
      const current = Object.getOwnPropertyDescriptor(geo, name);
      if (current?.value !== methods[name] || !current.configurable) continue;
      if (descriptor) Object.defineProperty(geo, name, descriptor);
      else Reflect.deleteProperty(geo, name);
    }
    geo = original = null;
  }

  // Chrome's Emulation.setTimezoneOverride and setLocaleOverride. WebKit
  // has neither, so Intl, toLocale*() and getTimezoneOffset() follow the
  // location's zone and locale; Date's own getters keep the system zone.
  let zone = null, zoneOriginals = null;
  function installZone() {
    const NativeDTF = Intl.DateTimeFormat, NativeNF = Intl.NumberFormat, NativeCollator = Intl.Collator;
    const dateProto = Date.prototype, numberProto = Number.prototype, stringProto = String.prototype;
    zoneOriginals = {
      DateTimeFormat: NativeDTF, NumberFormat: NativeNF, Collator: NativeCollator,
      toLocaleString: dateProto.toLocaleString, toLocaleDateString: dateProto.toLocaleDateString,
      toLocaleTimeString: dateProto.toLocaleTimeString, getTimezoneOffset: dateProto.getTimezoneOffset,
      numberToLocaleString: numberProto.toLocaleString, localeCompare: stringProto.localeCompare,
      language: Object.getOwnPropertyDescriptor(navigator, "language"),
      languages: Object.getOwnPropertyDescriptor(navigator, "languages"),
      languageValue: navigator.language, languagesValue: navigator.languages,
    };
    const locales = (value) => value ?? zone?.locale ?? undefined;
    const withZone = (options) => {
      const result = options == null ? {} : Object(options);
      return zone?.timezone && result.timeZone === undefined ? {...result, timeZone: zone.timezone} : result;
    };
    const wrapIntl = (Native, zoned) => {
      const Wrapped = function (value, options) {
        return new Native(locales(value), zoned ? withZone(options) : options);
      };
      Wrapped.prototype = Native.prototype;
      Wrapped.supportedLocalesOf = Native.supportedLocalesOf.bind(Native);
      return Wrapped;
    };
    const define = (target, name, value) =>
      Object.defineProperty(target, name, {configurable: true, writable: true, value});
    define(Intl, "DateTimeFormat", wrapIntl(NativeDTF, true));
    define(Intl, "NumberFormat", wrapIntl(NativeNF, false));
    define(Intl, "Collator", wrapIntl(NativeCollator, false));
    for (const name of ["toLocaleString", "toLocaleDateString", "toLocaleTimeString"]) {
      const native = zoneOriginals[name];
      define(dateProto, name, function (value, options) { return native.call(this, locales(value), withZone(options)); });
    }
    define(numberProto, "toLocaleString", function (value, options) {
      return zoneOriginals.numberToLocaleString.call(this, locales(value), options);
    });
    define(stringProto, "localeCompare", function (other, value, options) {
      return zoneOriginals.localeCompare.call(this, other, locales(value), options);
    });
    define(dateProto, "getTimezoneOffset", function () {
      if (!zone?.timezone) return zoneOriginals.getTimezoneOffset.call(this);
      const time = this.getTime();
      if (Number.isNaN(time)) return NaN;
      const parts = Object.fromEntries(new NativeDTF("en-US", {timeZone: zone.timezone, hourCycle: "h23",
        year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric"})
        .formatToParts(this).map(({type, value}) => [type, value]));
      const local = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour % 24, parts.minute, parts.second);
      return Math.round((Math.floor(time / 1000) * 1000 - local) / 60000);
    });
    Object.defineProperty(navigator, "language", {configurable: true, get: () => zone?.locale ?? zoneOriginals.languageValue});
    Object.defineProperty(navigator, "languages", {configurable: true,
      get: () => zone?.locale ? Object.freeze([zone.locale]) : zoneOriginals.languagesValue});
  }
  function restoreZone() {
    if (!zoneOriginals) return;
    const o = zoneOriginals;
    const define = (target, name, value) =>
      Object.defineProperty(target, name, {configurable: true, writable: true, value});
    define(Intl, "DateTimeFormat", o.DateTimeFormat);
    define(Intl, "NumberFormat", o.NumberFormat);
    define(Intl, "Collator", o.Collator);
    for (const name of ["toLocaleString", "toLocaleDateString", "toLocaleTimeString", "getTimezoneOffset"])
      define(Date.prototype, name, o[name]);
    define(Number.prototype, "toLocaleString", o.numberToLocaleString);
    define(String.prototype, "localeCompare", o.localeCompare);
    for (const name of ["language", "languages"]) {
      if (o[name]) Object.defineProperty(navigator, name, o[name]);
      else Reflect.deleteProperty(navigator, name);
    }
    zoneOriginals = null;
    zone = null;
  }

  // As Chrome's emulated sensor does, a deviceorientation listener added
  // while the override is on hears the angles too, not only those there
  // when it was set. Only window's own method is wrapped, and only then.
  const nativeAdd = EventTarget.prototype.addEventListener;
  function addListener(type, listener, options) {
    const result = Reflect.apply(nativeAdd, this, [type, listener, options]);
    if (orientation && this === window && String(type) === "deviceorientation" && listener) publishOrientation();
    return result;
  }
  function hookListeners() {
    if (Object.getOwnPropertyDescriptor(window, "addEventListener")) return;
    Object.defineProperty(window, "addEventListener", {configurable: true, writable: true, value: addListener});
  }
  function unhookListeners() {
    if (Object.getOwnPropertyDescriptor(window, "addEventListener")?.value === addListener)
      Reflect.deleteProperty(window, "addEventListener");
  }

  function publishOrientation() {
    clearTimeout(orientationTimer);
    orientationTimer = setTimeout(() => {
      if (!orientation) return;
      let event;
      const values = {...orientation, absolute: false};
      if (typeof DeviceOrientationEvent === "function") {
        try { event = new DeviceOrientationEvent("deviceorientation", values); } catch {}
      }
      if (!event) {
        event = new Event("deviceorientation");
        for (const [name, value] of Object.entries(values)) Object.defineProperty(event, name, {value});
      }
      window.dispatchEvent(event);
    }, 0);
  }

  function clearOrientation() {
    clearTimeout(orientationTimer);
    unhookListeners();
    window.removeEventListener("DOMContentLoaded", publishOrientation);
    orientation = null;
  }

  function apply(next) {
    if (next.zone) {
      if (!zoneOriginals) installZone();
      zone = {timezone: next.zone.timezone ?? null, locale: next.zone.locale ?? null};
    } else {
      restoreZone();
    }
    if (!next.location && position) restoreLocation();
    if (next.location) {
      if (!position) installLocation();
      const old = position;
      position = next.location;
      if (old && (old.latitude !== position.latitude || old.longitude !== position.longitude ||
                  old.accuracy !== position.accuracy || old.unavailable !== position.unavailable)) {
        for (const [id, [success, error]] of watches) send(success, error, id);
      }
    }
    const angles = next.orientation;
    if (orientation?.alpha === angles?.alpha && orientation?.beta === angles?.beta &&
        orientation?.gamma === angles?.gamma) return;
    clearOrientation();
    if (!angles) return;
    orientation = angles;
    hookListeners();
    if (document.readyState === "loading") {
      window.addEventListener("DOMContentLoaded", publishOrientation, {once: true});
    } else {
      publishOrientation();
    }
  }

  function dispose() {
    restoreZone();
    restoreLocation();
    clearOrientation();
    window.removeEventListener("pagehide", dispose, true);
    Reflect.deleteProperty(window, key);
  }

  try {
    apply(input);
    Object.defineProperty(window, key, {configurable: true, value: {apply, dispose}});
    // A document returned from the back-forward cache must not carry
    // fixtures after the inspector closed on a different document.
    window.addEventListener("pagehide", dispose, {once: true, capture: true});
    return true;
  } catch (error) {
    dispose();
    throw error;
  }
}