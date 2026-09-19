import Foundation
import IOKit

private let appVersion = "0.1.1"

struct GPUSnapshot: Codable {
    let index: Int
    let name: String
    let utilizationPercent: Double?
    let vramUsedBytes: UInt64?
    let vramTotalBytes: UInt64?
    let temperatureC: Double?
    let coreClockMHz: Double?
    let memoryClockMHz: Double?
    let powerW: Double?
}

struct AcceleratorSample {
    let properties: [String: Any]
    let statistics: [String: Any]
}

struct DisplayInfo {
    let name: String
    let vramTotalBytes: UInt64?
}

func numericValue(_ value: Any?) -> Double? {
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String {
        let cleaned = s
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "°C", with: "")
            .replacingOccurrences(of: "C", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }
    return nil
}

func metric(_ dictionary: [String: Any], exact keys: [String], contains fragments: [String] = []) -> Double? {
    for key in keys {
        if let value = numericValue(dictionary[key]) {
            return value
        }
    }

    let lowered = dictionary.reduce(into: [String: Any]()) { result, item in
        result[item.key.lowercased()] = item.value
    }

    for key in keys {
        if let value = numericValue(lowered[key.lowercased()]) {
            return value
        }
    }

    for fragment in fragments {
        let needle = fragment.lowercased()
        if let match = lowered.first(where: { $0.key.contains(needle) }),
           let value = numericValue(match.value) {
            return value
        }
    }

    return nil
}

func bytesMetric(_ dictionary: [String: Any], exact keys: [String], contains fragments: [String] = []) -> UInt64? {
    guard let value = metric(dictionary, exact: keys, contains: fragments), value >= 0 else {
        return nil
    }
    return UInt64(value)
}

func enumerateAccelerators() -> [AcceleratorSample] {
    var iterator: io_iterator_t = 0
    let matching = IOServiceMatching("IOAccelerator")
    let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)

    guard status == KERN_SUCCESS else {
        return []
    }

    defer { IOObjectRelease(iterator) }

    var samples: [AcceleratorSample] = []
    var service = IOIteratorNext(iterator)

    while service != 0 {
        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        let propertyStatus = IORegistryEntryCreateCFProperties(
            service,
            &unmanagedProperties,
            kCFAllocatorDefault,
            0
        )

        if propertyStatus == KERN_SUCCESS,
           let cfProperties = unmanagedProperties?.takeRetainedValue(),
           let properties = cfProperties as? [String: Any] {

            let stats = properties["PerformanceStatistics"] as? [String: Any] ?? [:]

            if !stats.isEmpty {
                samples.append(AcceleratorSample(properties: properties, statistics: stats))
            }
        }

        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }

    return samples
}

func parseMemoryString(_ value: String?) -> UInt64? {
    guard let value else { return nil }

    let parts = value
        .replacingOccurrences(of: ",", with: ".")
        .split(separator: " ")
        .map(String.init)

    guard let first = parts.first, let number = Double(first) else { return nil }

    let upper = value.uppercased()
    let multiplier: Double

    if upper.contains("TB") {
        multiplier = 1024 * 1024 * 1024 * 1024
    } else if upper.contains("GB") {
        multiplier = 1024 * 1024 * 1024
    } else if upper.contains("MB") {
        multiplier = 1024 * 1024
    } else if upper.contains("KB") {
        multiplier = 1024
    } else {
        multiplier = 1
    }

    return UInt64(number * multiplier)
}

func systemProfilerDisplays() -> [DisplayInfo] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["SPDisplaysDataType", "-json", "-detailLevel", "mini"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let displays = object["SPDisplaysDataType"] as? [[String: Any]] else {
            return []
        }

        return displays.map { item in
            let name = (item["sppci_model"] as? String)
                ?? (item["_name"] as? String)
                ?? "Unknown GPU"

            let vram = parseMemoryString(
                (item["spdisplays_vram"] as? String)
                ?? (item["spdisplays_vram_shared"] as? String)
            )

            return DisplayInfo(name: name, vramTotalBytes: vram)
        }
    } catch {
        return []
    }
}

// Model name and total VRAM do not change while the process is running.
// Cache them once so --watch only polls the lightweight IOKit counters.
private let cachedDisplayInfo = systemProfilerDisplays()

func snapshots() -> [GPUSnapshot] {
    let samples = enumerateAccelerators()

    return samples.enumerated().map { offset, sample in
        let stats = sample.statistics

        let utilization = metric(
            stats,
            exact: [
                "Device Utilization %",
                "GPU Utilization %",
                "GPU Activity(%)",
                "GPU Activity %",
                "GPU Core Utilization"
            ],
            contains: ["device utilization", "gpu utilization", "gpu activity"]
        )

        let usedVRAM = bytesMetric(
            stats,
            exact: [
                "VRAM Used Bytes",
                "vramUsedBytes",
                "VRAM,usedBytes",
                "VRAM Used"
            ],
            contains: ["vram used"]
        )

        let totalVRAMFromStats = bytesMetric(
            stats,
            exact: [
                "VRAM Total Bytes",
                "vramTotalBytes",
                "VRAM,totalBytes",
                "VRAM Total"
            ],
            contains: ["vram total"]
        )

        let temperature = metric(
            stats,
            exact: [
                "Temperature(C)",
                "GPU Temperature(C)",
                "GPU Temperature",
                "Temperature"
            ],
            contains: ["temperature"]
        )

        let coreClock = metric(
            stats,
            exact: [
                "Core Clock(MHz)",
                "GPU Core Clock(MHz)",
                "Core Clock MHz",
                "GPU Clock(MHz)"
            ],
            contains: ["core clock"]
        )

        let memoryClock = metric(
            stats,
            exact: [
                "Memory Clock(MHz)",
                "VRAM Clock(MHz)",
                "Memory Clock MHz"
            ],
            contains: ["memory clock", "vram clock"]
        )

        let power = metric(
            stats,
            exact: [
                "GPU Power(W)",
                "Power(W)",
                "GPU Power"
            ],
            contains: ["gpu power"]
        )

        let displayInfo = offset < cachedDisplayInfo.count ? cachedDisplayInfo[offset] : nil
        let name = displayInfo?.name
            ?? (sample.properties["IOClass"] as? String)
            ?? "GPU \(offset)"

        let totalVRAM = totalVRAMFromStats ?? displayInfo?.vramTotalBytes

        return GPUSnapshot(
            index: offset,
            name: name,
            utilizationPercent: utilization,
            vramUsedBytes: usedVRAM,
            vramTotalBytes: totalVRAM,
            temperatureC: temperature,
            coreClockMHz: coreClock,
            memoryClockMHz: memoryClock,
            powerW: power
        )
    }
}

func formatPercent(_ value: Double?) -> String {
    guard let value else { return "N/A" }
    return String(format: "%.1f%%", value)
}

func formatTemperature(_ value: Double?) -> String {
    guard let value else { return "N/A" }
    return String(format: "%.0f C", value)
}

func formatPower(_ value: Double?) -> String {
    guard let value else { return "N/A" }
    return String(format: "%.1f W", value)
}

func formatClock(_ value: Double?) -> String {
    guard let value else { return "N/A" }
    return String(format: "%.0f MHz", value)
}

func formatBytes(_ value: UInt64?) -> String {
    guard let value else { return "N/A" }
    return String(format: "%.1f GB", Double(value) / 1_073_741_824.0)
}

func pad(_ value: String, to width: Int) -> String {
    if value.count >= width {
        return String(value.prefix(width))
    }
    return value + String(repeating: " ", count: width - value.count)
}

func printTable(_ values: [GPUSnapshot]) {
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    print("mac-gpu-monitor \(appVersion)   \(osVersion)")
    print("+------------------------------------------------------------------------------------------------+")
    print("| GPU  Name                             Util     VRAM Used / Total       Temp      Power           |")
    print("|------------------------------------------------------------------------------------------------|")

    if values.isEmpty {
        print("| No IOAccelerator PerformanceStatistics entries were found.                                    |")
    } else {
        for gpu in values {
            let vram: String
            if gpu.vramUsedBytes != nil || gpu.vramTotalBytes != nil {
                vram = "\(formatBytes(gpu.vramUsedBytes)) / \(formatBytes(gpu.vramTotalBytes))"
            } else {
                vram = "N/A"
            }

            let row =
                "| " +
                pad(String(gpu.index), to: 4) +
                pad(gpu.name, to: 33) +
                pad(formatPercent(gpu.utilizationPercent), to: 9) +
                pad(vram, to: 24) +
                pad(formatTemperature(gpu.temperatureC), to: 10) +
                pad(formatPower(gpu.powerW), to: 16) +
                "|"
            print(row)
        }
    }

    print("+------------------------------------------------------------------------------------------------+")

    for gpu in values {
        if gpu.coreClockMHz != nil || gpu.memoryClockMHz != nil {
            print("GPU \(gpu.index) clocks: core \(formatClock(gpu.coreClockMHz)), memory \(formatClock(gpu.memoryClockMHz))")
        }
    }
}

func printJSON(_ values: [GPUSnapshot]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    do {
        let data = try encoder.encode(values)
        if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    } catch {
        fputs("Failed to encode JSON: \(error)\n", stderr)
        exit(1)
    }
}

func rawValueDescription(_ value: Any) -> String {
    if let data = value as? Data {
        return "<Data \(data.count) bytes>"
    }
    return String(describing: value)
}

func printRaw() {
    let samples = enumerateAccelerators()

    if samples.isEmpty {
        print("No IOAccelerator PerformanceStatistics entries found.")
        return
    }

    for (index, sample) in samples.enumerated() {
        let name = index < cachedDisplayInfo.count ? cachedDisplayInfo[index].name : "GPU \(index)"
        print("GPU \(index) \(name) PerformanceStatistics")
        print(String(repeating: "-", count: 72))

        for key in sample.statistics.keys.sorted() {
            if let value = sample.statistics[key] {
                print("\(key) = \(rawValueDescription(value))")
            }
        }

        if index + 1 < samples.count {
            print("")
        }
    }
}

func printHelp() {
    print("""
    mac-gpu-monitor \(appVersion)

    Usage:
      gpu-monitor
      gpu-monitor --watch [seconds]
      gpu-monitor --json
      gpu-monitor --raw
      gpu-monitor --help
      gpu-monitor --version

    Options:
      -w, --watch [seconds]  Continuously refresh. Default interval: 1 second.
      -j, --json             Print machine-readable JSON.
      -r, --raw              Print all PerformanceStatistics keys exposed by the driver.
      -h, --help             Show this help.
          --version          Show version.
    """)
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    printHelp()
    exit(0)
}

if arguments.contains("--version") {
    print(appVersion)
    exit(0)
}

if arguments.contains("--raw") || arguments.contains("-r") {
    printRaw()
    exit(0)
}

let jsonMode = arguments.contains("--json") || arguments.contains("-j")

if let watchIndex = arguments.firstIndex(where: { $0 == "--watch" || $0 == "-w" }) {
    var interval = 1.0

    if watchIndex + 1 < arguments.count,
       let parsed = Double(arguments[watchIndex + 1]),
       parsed > 0 {
        interval = parsed
    }

    while true {
        if isatty(STDOUT_FILENO) != 0 {
            print("\u{001B}[2J\u{001B}[H", terminator: "")
        }

        let values = snapshots()
        if jsonMode {
            printJSON(values)
        } else {
            printTable(values)
        }

        fflush(stdout)
        Thread.sleep(forTimeInterval: interval)
    }
} else {
    let values = snapshots()

    if jsonMode {
        printJSON(values)
    } else {
        printTable(values)
    }
}
