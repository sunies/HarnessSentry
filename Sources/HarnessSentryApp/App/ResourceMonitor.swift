import Darwin
import Foundation
import HarnessSentryCore

/// Samples only this process. It never inspects or attaches to a monitored Harness.
@MainActor
final class ResourceMonitor {
    private var previousWallTime = ProcessInfo.processInfo.systemUptime
    private var previousCPUTime = ResourceMonitor.processCPUTime()
    private var cpuSamples: [Double] = []
    private var hasSampled = false

    func sample(databaseBytes: Int64, databaseLimitBytes: Int64) -> ResourceHealthSnapshot {
        let wallTime = ProcessInfo.processInfo.systemUptime
        let cpuTime = Self.processCPUTime()
        let wallDelta = max(wallTime - previousWallTime, 0.001)
        let cpuPercent = max(0, (cpuTime - previousCPUTime) / wallDelta * 100)
        previousWallTime = wallTime
        previousCPUTime = cpuTime

        // Launch work can produce a misleading first interval of a few milliseconds.
        // Wait for a few real intervals before treating CPU use as sustained pressure.
        cpuSamples.append(hasSampled ? cpuPercent : 0)
        hasSampled = true
        if cpuSamples.count > 6 { cpuSamples.removeFirst(cpuSamples.count - 6) }
        let average = cpuSamples.count >= 3
            ? cpuSamples.reduce(0, +) / Double(cpuSamples.count)
            : 0

        return ResourceHealthSnapshot(
            cpuAveragePercent: average,
            residentMemoryBytes: Self.residentMemoryBytes(),
            databaseBytes: databaseBytes,
            databaseLimitBytes: databaseLimitBytes
        )
    }

    private static func processCPUTime() -> TimeInterval {
        Double(clock()) / Double(CLOCKS_PER_SEC)
    }

    private static func residentMemoryBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}
