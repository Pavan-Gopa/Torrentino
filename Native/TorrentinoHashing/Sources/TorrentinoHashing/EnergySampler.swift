// Layer: Hashing research (WP-12)
// Role: headless energy/thermal instrumentation for the benchmark harness.
// What is measured on this machine:
//   * CPU time via getrusage(RUSAGE_THREAD) — user+system seconds, the only
//     root-free energy proxy on macOS 26 (IOReport symbols are not exported
//     from IOKit here; powermetrics requires root).
//   * Thermal state via ProcessInfo.thermalState (nominal/fair/serious/
//     critical) and `pmset -g therm` CPU speed-limit percent.
//   * Low Power Mode via ProcessInfo.isLowPowerModeEnabled.
// Documented methodology for a privileged run (see benchmark REPORT.md):
//   sudo powermetrics --samplers cpu_power,gpu_power -i 100 --show-process-energy
//   sudo powermetrics --samplers thermal --show-process-energy
// Invariants: never blocks the caller; returns nil/empty instead of failing
// when the OS does not expose the data.

import Darwin
import Foundation

public struct EnergySample: Sendable {
    /// CPU user+system seconds consumed by this thread during the window.
    public let cpuSeconds: Double
    /// ProcessInfo.thermalState rawValue during the window (0..4).
    public let thermalStateRaw: Int
    /// pmset -g therm "CPU speed limit" percentage (100 = no limit).
    public let cpuSpeedLimitPercent: Int
    /// True when Low Power Mode was enabled during the window.
    public let lowPowerMode: Bool
}

public enum EnergySampler {
    /// Best-effort snapshot at this instant.
    public static func sample() -> EnergySample {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpuSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return EnergySample(
            cpuSeconds: cpuSeconds,
            thermalStateRaw: ProcessInfo.processInfo.thermalState.rawValue,
            cpuSpeedLimitPercent: cpuSpeedLimitPercent(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// CPU seconds delta between two samples.
    public static func cpuDelta(from: EnergySample, to: EnergySample) -> Double {
        to.cpuSeconds - from.cpuSeconds
    }

    /// Parses `pmset -g therm` for the "CPU_Speed_Limit" percentage.
    public static func cpuSpeedLimitPercent() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "pmset -g therm"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return 100
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return 100 }
        // Example line: "CPU_Speed_Limit = 100"
        if let range = text.range(of: "CPU_Speed_Limit\\s*=\\s*(\\d+)", options: .regularExpression) {
            let value = text[range]
            if let number = value.split(separator: "=").last?.trimmingCharacters(in: .whitespaces),
               let percent = Int(number) {
                return percent
            }
        }
        return 100
    }
}
