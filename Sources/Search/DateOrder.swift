import Foundation

// `<=` and `>=` between two Dates, written here rather than taken from
// Foundation.
//
// The macOS 27.2 SDK gives Date its own `<=` and `>=`, back-deployed: built
// against it, every `a <= b` on Dates becomes a check for macOS 27.2 and, when
// it passes, a call into Foundation's copy, weakly linked. Some builds of
// macOS 27.2 (26B5091g) pass the check yet have no such copy, so the call
// jumped to address 0 and Search crashed: building the menu bar (Reopen Closed
// Tab, ⌘Z), on the look for tabs to close, and anywhere else two dates are
// compared.
//
// Declared in this module, these are the ones Swift picks for every `<=` and
// `>=` on Dates in Search, and both stand on `<`, which every macOS has. A
// build importing Foundation's again shows up as
// `dyld_info -fixups .build/release/Search | grep 'DateV2[lg]e'`.
extension Date {
    @inline(__always) static func <= (lhs: Date, rhs: Date) -> Bool { !(rhs < lhs) }
    @inline(__always) static func >= (lhs: Date, rhs: Date) -> Bool { !(lhs < rhs) }
}
