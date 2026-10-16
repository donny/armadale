import Darwin

/// Memory footprint of another process, as Activity Monitor reports it
/// (`ri_phys_footprint` from `proc_pid_rusage`). One non-blocking system
/// call; safe to make from any thread.
public enum ProcessFootprint {
    /// The footprint of `pid` in bytes, or `nil` if it cannot be read (the
    /// process is gone, or belongs to another user).
    public static func bytes(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }
}
