// Privacy-safe process sampling: numeric usage and window visibility only.
// proc_pid_rusage CPU totals use Mach ticks. getrusage timeval already uses seconds;
// never apply this scaling to getrusage-based benchmark measurements.
// References: Apple XNU osfmk/kern/bsd_kern.c fill_task_rusage.
import AppKit
import Foundation
import Darwin
@_silgen_name("proc_pid_rusage")
func readUsage(_ pid: Int32, _ flavor: Int32, _ data: UnsafeMutableRawPointer) -> Int32
setbuf(stdout, nil)
func usage() -> rusage_info_v2 {
    var r = rusage_info_v2()
    precondition(withUnsafeMutablePointer(to: &r) { readUsage(getpid(), 2, UnsafeMutableRawPointer($0)) } == 0)
    return r
}
func seconds(_ r: rusage) -> Double {
    Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
}
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--self-check" {
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    let before = usage(); var r0 = rusage(); getrusage(RUSAGE_SELF, &r0)
    let deadline = ProcessInfo.processInfo.systemUptime + 0.2
    var checksum: UInt64 = 0
    while ProcessInfo.processInfo.systemUptime < deadline { checksum &+= 1 }
    var r1 = rusage(); getrusage(RUSAGE_SELF, &r1); let after = usage()
    let converted = Double(after.ri_user_time - before.ri_user_time + after.ri_system_time - before.ri_system_time) * Double(tb.numer) / Double(tb.denom) / 1e9
    let reference = seconds(r1) - seconds(r0)
    precondition(abs(converted - reference) < max(0.005, reference * 0.05), "CPU time conversion disagrees with getrusage")
    print("CPU calibration passed: converted=\(converted) getrusage=\(reference) timebase=\(tb.numer)/\(tb.denom) checksum=\(checksum)")
    exit(0)
}
guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]), pid > 0,
      let durationCheck = Double(CommandLine.arguments[2]), durationCheck.isFinite, durationCheck > 0, durationCheck <= 3600 else {
    fputs("Usage: sampler PID SECONDS (1..3600), or --self-check\n", stderr); exit(64)
}
let duration = Double(CommandLine.arguments[2])!
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let ticksToNS = Double(timebase.numer) / Double(timebase.denom)
let start = Date()
var initial: UInt64?
var binary: Data?
while Date().timeIntervalSince(start) < duration {
    var usage = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &usage) { readUsage(pid, 2, UnsafeMutableRawPointer($0)) }
    guard result == 0 else { fputs("Process exited; sample invalidated.\n", stderr); exit(2) }
    let uuid = withUnsafeBytes(of: usage.ri_uuid) { Data($0) }
    if let initial, let binary {
        guard initial == usage.ri_proc_start_abstime, binary == uuid else { fputs("Process/build changed; sample invalidated.\n", stderr); exit(2) }
    } else { initial = usage.ri_proc_start_abstime; binary = uuid }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let visible = windows.contains { row in
        guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              let bounds = row[kCGWindowBounds as String] as? [String: NSNumber] else { return false }
        return (bounds["Width"]?.doubleValue ?? 0) > 150 && (bounds["Height"]?.doubleValue ?? 0) > 40
            && ((row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 100) < 10
    }
    let active = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    let phase = visible && active ? "foreground" : (!visible && !active ? "background" : "transition")
    let row: [String: Any] = ["cpu_time_unit": "nanoseconds", "mach_timebase_numer": timebase.numer, "mach_timebase_denom": timebase.denom, "elapsed": Date().timeIntervalSince(start), "phase": phase, "active": active, "content_visible": visible,
        "disk_read": usage.ri_diskio_bytesread, "disk_write": usage.ri_diskio_byteswritten, "wakeups": usage.ri_pkg_idle_wkups, "footprint": usage.ri_phys_footprint, "user_ns": Double(usage.ri_user_time) * ticksToNS, "system_ns": Double(usage.ri_system_time) * ticksToNS]
    print(String(data: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
    RunLoop.current.run(until: Date().addingTimeInterval(1))
}
