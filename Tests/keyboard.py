"""Key codes for this Mac's keyboard layout, for probes that press keys.

Search reads a shortcut's key the way the keyboard's own layout names it
(KeyCombo(event:)), from the key code. A probe that presses ⌘= as key code
24, where = sits on a US keyboard, presses ⌘- on a French one, and zooms
out. `code("=")` is the key that types = on the layout in use (44 on
French AZERTY), or None where no key types it without ⇧ or ⌥, as [ and ]
on AZERTY: a check of that shortcut can't be pressed on this keyboard.
"""
import ctypes
import ctypes.util

_codes = None


def _read():
    carbon = ctypes.cdll.LoadLibrary(ctypes.util.find_library("Carbon"))
    cf = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))
    carbon.TISCopyCurrentKeyboardLayoutInputSource.restype = ctypes.c_void_p
    carbon.TISGetInputSourceProperty.restype = ctypes.c_void_p
    carbon.TISGetInputSourceProperty.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    cf.CFDataGetBytePtr.restype = ctypes.c_void_p
    cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    carbon.LMGetKbdType.restype = ctypes.c_uint8
    carbon.UCKeyTranslate.argtypes = [
        ctypes.c_void_p, ctypes.c_uint16, ctypes.c_uint16, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
        ctypes.POINTER(ctypes.c_uint32), ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_uint16)]
    source = carbon.TISCopyCurrentKeyboardLayoutInputSource()
    found = {}
    try:
        data = carbon.TISGetInputSourceProperty(source, ctypes.c_void_p.in_dll(carbon, "kTISPropertyUnicodeKeyLayoutData"))
        layout = cf.CFDataGetBytePtr(data) if data else None
        if not layout:
            return found
        # The keypad's last: ⌘0 and the rest are the main keys' to answer.
        for key in sorted(range(128), key=lambda k: 65 <= k <= 92):
            dead, length, typed = ctypes.c_uint32(0), ctypes.c_ulong(0), (ctypes.c_uint16 * 4)()
            # kUCKeyActionDisplay, no modifiers, no dead keys.
            if carbon.UCKeyTranslate(layout, key, 3, 0, carbon.LMGetKbdType(), 1, ctypes.byref(dead), 4,
                                     ctypes.byref(length), typed) == 0 and length.value:
                found.setdefault("".join(map(chr, typed[:length.value])).lower(), key)
    finally:
        if source:
            cf.CFRelease(source)
    return found


def code(chars):
    """The key code that types `chars` with nothing held, or None."""
    global _codes
    if _codes is None:
        try:
            _codes = _read()
        except (OSError, ValueError, AttributeError):
            _codes = {}
    return _codes.get(chars.lower())
