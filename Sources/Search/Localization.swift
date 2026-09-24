import Foundation

// A one-line lookup so every user-facing string in the app goes through the
// same door. `build.sh` copies Localization/*.lproj into Contents/Resources,
// so this reads from Bundle.main exactly like NSLocalizedString always has —
// no SwiftPM resource bundle, no Bundle.module indirection.
func L(_ key: String, comment: String = "") -> String {
    NSLocalizedString(key, bundle: .main, comment: comment)
}

// For strings with a runtime value spliced in. Callers stringify the value
// themselves (`"\(count)"`) and the format string always uses %@, so there is
// one splicing convention for every type instead of %d/%ld/%@ per call site.
func L(_ format: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(format, bundle: .main, comment: ""), arguments: args)
}
