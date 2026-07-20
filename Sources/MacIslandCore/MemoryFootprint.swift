import Foundation

/// The one memory reading the performance budget is written against: **phys
/// footprint** — the same number Activity Monitor's "Memory" column, the `footprint`
/// command-line tool, and `XCTMemoryMetric` report, and the one the budget's ≤100 MB
/// ceiling and no-leak check are stated in (perf spec §1.3 — *not* virtual size).
///
/// Read straight from the kernel via mach `task_info(TASK_VM_INFO)`, so a headless
/// XCTest can assert the process's live footprint with no tooling and no wall-clock
/// wait. Apple frameworks only (`Darwin`/Foundation) — no third-party dependency, in
/// keeping with the core's zero-dep rule (spec §4).
public enum MemoryFootprint {
    /// This process's current physical footprint, in bytes — or `nil` if the kernel
    /// query fails (a test treats that as "unavailable on this host" and skips, never a
    /// false failure).
    public static func current() -> UInt64? {
        var info = task_vm_info_data_t()
        // `phys_footprint` lives near the end of `task_vm_info`, so the request must be
        // sized for the whole struct (not the smaller legacy count) or the field reads
        // back zero.
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }
}
