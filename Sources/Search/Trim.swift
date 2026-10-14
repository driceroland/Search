import AppKit
import Darwin

// Memory the app has finished with, handed back to the Mac.
//
// An extension's declarativeNetRequest rules are compiled by WebKit inside
// this process: all of them, every time the extension changes any. AdBlock's
// lists come to 150 MB compiled, and building them takes the app from under
// a hundred megabytes to over a gigabyte for a minute — at launch, and again
// each time it fetches a filter update. When it is done, a few dozen
// megabytes are still in use; the rest has been freed, but malloc keeps the
// pages it freed dirty and counted against Search, in Activity Monitor and
// by macOS when it decides what to squeeze. Measured: 1153 MB of footprint
// around 44 MB of live allocations.
//
// So every half minute the footprint is read — one kernel call — and when it
// has grown by a good margin since the last look, malloc is asked to give
// back what it is holding empty. Same when the app goes to the background.
// The work is a walk over malloc's free lists, off the main thread.
enum Trim {
    /// Growth worth a walk. Below this, what comes back isn't worth noticing.
    private static let margin: UInt64 = 64 << 20
    /// Read and written on `queue` only.
    private static var after: UInt64 = 0
    private static var timer: DispatchSourceTimer?
    private static let queue = DispatchQueue(label: "com.officecommun.search.trim", qos: .utility)

    /// Started once, at launch.
    static func start() {
        queue.async {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
            source.setEventHandler { if footprint() > after + margin { relieve() } }
            source.resume()
            timer = source
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: nil
        ) { _ in queue.async { relieve() } }
    }

    private static func relieve() {
        malloc_zone_pressure_relief(nil, 0)
        after = footprint()
    }

    /// What Activity Monitor calls Memory for this process.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
