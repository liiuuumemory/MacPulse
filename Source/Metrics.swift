import Foundation
import IOKit
import Darwin

struct SensorValue: Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let value: Double
    let kind: String
}
/// One fan: its current speed and the min…max range the SMC reports for it.
struct FanReading: Equatable {
    let rpm: Double
    let min: Double
    let max: Double
    var fraction: Double { max > min ? Swift.min(1, Swift.max(0, (rpm - min) / (max - min))) : 0 }
}
struct NetworkValue: Identifiable {
    var id: String { name }
    let name: String
    var address: String = ""
    var received: UInt64 = 0
    var sent: UInt64 = 0
    var download: Double = 0
    var upload: Double = 0
    var fullCounters = false
}
struct ProcessUsage: Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    var cpu: Double? // percent of one core; may exceed 100 for multithreaded work
    let memory: Double // physical footprint, as Activity Monitor's Memory column
}
struct Sample {
    var date = Date()
    var cpu: Double?
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cores: [Double] = []
    var gpu: Double?
    var memoryUsed: Double = 0
    var memoryTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    var compressed: Double = 0
    var swap: Double = 0
    var pressure = "未知"
    var memoryValid = false
    var load: [Double] = []
    var diskTotal: Double = 0
    var diskFree: Double = 0
    var diskRead: Double?
    var diskWrite: Double?
    var networks: [NetworkValue] = []
    var networkValid = false
    var sensors: [SensorValue] = []
    var watts: Double?
    var cpuPower: Double? // AppleCLPC energy counters, watts
    var gpuPower: Double?
    var anePower: Double?
    var powerSource = "传感器不可用"
    var cpuTemp: Double?
    var gpuTemp: Double?
    var batteryPercent: Double?
    var batteryHealth: Double? // full-charge capacity as % of design capacity
    var batteryCycles: Int?
    var batteryDesignCycles: Int?
    var batteryCapacity: (full: Double, design: Double)?
    var charging = false
    var processes: [ProcessUsage] = []
    var processesHidden = 0 // processes owned by other users, unreadable without privileges
    var thermal = "正常"
    var uptime = ProcessInfo.processInfo.systemUptime
    var smcAvailable = false
    /// Every fan the SMC reports, in its own order; empty on fanless Macs.
    var fans: [FanReading] = []
    var sensorsComplete = true
}

func sysString(_ name: String) -> String {
    var count = 0
    guard sysctlbyname(name, nil, &count, nil, 0) == 0, count > 0 else { return "Mac" }
    var chars = [CChar](repeating: 0, count: count)
    guard sysctlbyname(name, &chars, &count, nil, 0) == 0 else { return "Mac" }
    return String(cString: chars)
}
func registry(_ service: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}
func services(_ name: String) -> [io_service_t] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var result: [io_service_t] = []
    while true {
        let object = IOIteratorNext(iterator)
        if object == 0 { break }
        result.append(object)
    }
    return result
}
func counterDelta(_ current: UInt64, _ previous: UInt64) -> Double {
    current >= previous ? Double(current - previous) : 0
}

func parseNetworkCounters(_ text: String) -> [String: (UInt64, UInt64)] {
    var result: [String: (UInt64, UInt64)] = [:]
    for line in text.split(separator: "\n") {
        let columns = line.split(whereSeparator: { $0.isWhitespace })
        guard columns.count >= 10, columns[0].hasPrefix("en"), columns[2].hasPrefix("<Link#"),
              let received = UInt64(columns[6]), let sent = UInt64(columns[9]) else { continue }
        result[String(columns[0])] = (received, sent)
    }
    return result
}

private func systemNetworkCounters() -> [String: (UInt64, UInt64)] {
    // On this OS, even NET_RT_IFLIST2 is quantized/truncated for ordinary apps.
    // Apple's netstat returns full counters under its own system entitlement.
    // Run the fixed system executable directly via posix_spawn, with no shell or elevated access.
    var buffer = [CChar](repeating: 0, count: 256 * 1024)
    let length = mp_netstat(&buffer, buffer.count)
    guard length > 0 else { return [:] }
    return parseNetworkCounters(buffer.withUnsafeBytes { String(decoding: $0.prefix(length), as: UTF8.self) })
}

final class MetricsCollector {
    private var smc: UInt32 = 0
    private var sensorKeys: [(key: String, name: String)] = []
    private var smcInfo: [String: (type: UInt32, size: UInt32)] = [:]
    private var summaryTemperatures: (time: TimeInterval, values: [SensorValue])?
    /// Fan min/max never change while running; read them once per fan.
    private var fanRanges: [Int: (min: Double, max: Double)] = [:]
    private var previousCPU: [UInt32]?
    private var previousNetwork: [String: NetworkValue] = [:]
    private var previousDisk: [UInt64: (UInt64, UInt64)] = [:]
    private var previousTime: TimeInterval?
    private var previousProcess: [pid_t: UInt64] = [:]
    private var processNames: [pid_t: String] = [:]
    private let ticksToNanoseconds: Double = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(info.numer) / Double(max(1, info.denom))
    }()
    private let host = mach_host_self()
    let chip = sysString("machdep.cpu.brand_string")
    let model = sysString("hw.model")

    private var powerCounters = false
    private var powerBaseline: TimeInterval?
    private var lastPower: (time: TimeInterval, watts: [Double])?
    init() { discoverSensors(); powerCounters = mp_power_open() == 1 }
    deinit { mp_smc_close(smc); mp_power_close(); mach_port_deallocate(mach_task_self_, host) }
    func reset() {
        previousTime = nil; previousCPU = nil
        previousNetwork = [:]; previousDisk = [:]; previousProcess = [:]
        mp_smc_close(smc); smc = 0; discoverSensors()
        powerCounters = mp_power_open() == 1
        powerBaseline = nil; lastPower = nil
    }
    private func readSMC(_ key: String) -> Double? {
        var value = 0.0
        if let info = smcInfo[key] { return mp_smc_read_info(smc, key, info.type, info.size, &value) == 1 ? value : nil }
        var type: UInt32 = 0, size: UInt32 = 0
        guard mp_smc_info(smc, key, &type, &size) == 1 else { return nil }
        smcInfo[key] = (type, size)
        return mp_smc_read_info(smc, key, type, size, &value) == 1 ? value : nil
    }
    static func sensorName(_ key: String) -> String {
        if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("TC0") { return "CPU" }
        if key.hasPrefix("Tg") || key.hasPrefix("TG0") { return "GPU" }
        if key.hasPrefix("Tm") { return "内存" }
        if key.hasPrefix("TH") || key.hasPrefix("TN0") { return "SSD" }
        if key.hasPrefix("TW") { return "无线模块" }
        if key.hasPrefix("TB") { return "电池" }
        if key.hasPrefix("TCM") { return "SoC" }
        return "其他温度"
    }
    private func discoverSensors() {
        smc = mp_smc_open()
        sensorKeys = []; smcInfo = [:]; summaryTemperatures = nil
        guard let count = readSMC("#KEY"), count > 0, count < 20000 else { return }
        for index in 0..<Int(count) {
            var bytes = [CChar](repeating: 0, count: 5)
            guard mp_smc_key(smc, UInt32(index), &bytes) == 1 else { continue }
            let key = String(cString: bytes)
            // Known temperature namespaces, excluding temperature configuration/status keys.
            if ["Tp", "Te", "Tg", "Tm", "Tf"].contains(where: { key.hasPrefix($0) }) ||
                ["TCMb", "TCMz", "TC0P", "TC0D", "TG0P", "TH0x", "TH0B", "TN00", "TN01", "TW0P", "TB1T", "TB2T", "TaLP", "TaRF"].contains(key) {
                sensorKeys.append((key, Self.sensorName(key)))
            }
        }
        sensorKeys.sort { $0.key < $1.key }
    }
    /// `detailed` reads every sensor for visible panels; otherwise only what the menu bar,
    /// alerts and the CPU/GPU summaries need.
    func sample(detailed: Bool = true) -> Sample {
        var s = Sample()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime.map { now - $0 }
        // Never average a wakeup/reset gap into live rates.
        let dt = elapsed.flatMap { $0 > 0 && $0 < 30 ? $0 : nil }
        if dt == nil { previousCPU = nil; previousNetwork = [:]; previousDisk = [:]; previousProcess = [:] }
        defer { previousTime = now }
        readCPU(&s)
        readMemory(&s)
        readNetwork(&s, dt: dt)
        readDisk(&s, dt: dt)
        readGPU(&s)
        readSensors(&s, detailed: detailed)
        readPower(&s, detailed: detailed, now: now)
        readBattery(&s)
        // Walking ~500 processes is only worth it while someone can see the list.
        if detailed { readProcesses(&s, dt: dt) } else { previousProcess = [:] }
        var average = [Double](repeating: 0, count: 3)
        if getloadavg(&average, 3) == 3 { s.load = average }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: s.thermal = "正常"
        case .fair: s.thermal = "温热"
        case .serious: s.thermal = "较高"
        case .critical: s.thermal = "过热"
        @unknown default: s.thermal = "未知"
        }
        return s
    }
    private func readCPU(_ s: inout Sample) {
        var count: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &count) == KERN_SUCCESS,
              let pointer = info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: pointer)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let current = (0..<Int(count)).map { UInt32(bitPattern: pointer[$0]) }
        defer { previousCPU = current }
        guard let old = previousCPU, old.count == current.count else { return }
        var total: Double = 0, user: Double = 0, system: Double = 0
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            let u = Double(current[base + Int(CPU_STATE_USER)] &- old[base + Int(CPU_STATE_USER)])
            let sy = Double(current[base + Int(CPU_STATE_SYSTEM)] &- old[base + Int(CPU_STATE_SYSTEM)])
            let idle = Double(current[base + Int(CPU_STATE_IDLE)] &- old[base + Int(CPU_STATE_IDLE)])
            let nice = Double(current[base + Int(CPU_STATE_NICE)] &- old[base + Int(CPU_STATE_NICE)])
            let sum = u + sy + idle + nice
            s.cores.append(sum > 0 ? (u + sy + nice) / sum * 100 : 0)
            total += sum; user += u + nice; system += sy
        }
        if total > 0 { s.cpuUser = user / total * 100; s.cpuSystem = system / total * 100; s.cpu = s.cpuUser + s.cpuSystem }
    }
    private func readMemory(_ s: inout Sample) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        if result == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let usedPages = Double(stats.active_count) + Double(stats.inactive_count) + Double(stats.wire_count) + Double(stats.compressor_page_count) - Double(stats.purgeable_count) - Double(stats.external_page_count)
            s.memoryUsed = min(s.memoryTotal, max(0, usedPages * page))
            s.compressed = Double(stats.compressor_page_count) * page
            s.memoryValid = true
        }
        var swap = xsw_usage()
        var length = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &length, nil, 0) == 0 { s.swap = Double(swap.xsu_used) }
        var pressure: Int32 = 0
        length = MemoryLayout<Int32>.stride
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &length, nil, 0) == 0 {
            s.pressure = pressure == 1 ? "正常" : pressure == 2 ? "偏高" : pressure == 4 ? "紧张" : "未知"
        }
    }
    private func readNetwork(_ s: inout Sample, dt: Double?) {
        let fullCounters = systemNetworkCounters()
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return }
        defer { freeifaddrs(first) }
        s.networkValid = true
        var entries: [String: NetworkValue] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            defer { cursor = entry.ifa_next }
            let name = String(cString: entry.ifa_name)
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.ifa_addr else { continue }
            // Physical Ethernet/Wi-Fi only. VPN, AWDL and bridges would double-count the same traffic.
            guard name.hasPrefix("en") else { continue }
            var item = entries[name] ?? NetworkValue(name: name)
            if Int32(address.pointee.sa_family) == AF_LINK, let raw = entry.ifa_data {
                let data = raw.assumingMemoryBound(to: if_data.self).pointee
                item.received = UInt64(data.ifi_ibytes); item.sent = UInt64(data.ifi_obytes)
            } else if Int32(address.pointee.sa_family) == AF_INET {
                var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 { item.address = String(cString: text) }
            } else if Int32(address.pointee.sa_family) == AF_INET6, item.address.isEmpty {
                var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 { item.address = String(cString: text) }
            }
            entries[name] = item
        }
        for name in entries.keys.sorted() {
            var entry = entries[name]!
            var received: UInt64 = 0, sent: UInt64 = 0
            if let full = fullCounters[name] {
                entry.received = full.0; entry.sent = full.1
                entry.fullCounters = true
                entries[name] = entry
            } else if mp_network_counters(name, &received, &sent) == 1 {
                entry.received = received; entry.sent = sent
                entries[name] = entry
            }
            if let old = previousNetwork[name], old.fullCounters == entry.fullCounters, let dt {
                entry.download = counterDelta(entry.received, old.received) / dt
                entry.upload = counterDelta(entry.sent, old.sent) / dt
            }
            s.networks.append(entry)
        }
        previousNetwork = entries
    }
    private func readDisk(_ s: inout Sample, dt: Double?) {
        if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
            s.diskTotal = Double(values.volumeTotalCapacity ?? 0)
            s.diskFree = Double(values.volumeAvailableCapacity ?? 0)
        }
        var current: [UInt64: (UInt64, UInt64)] = [:]
        var reads = 0.0, writes = 0.0
        let objects = services("IOBlockStorageDriver")
        for object in objects {
            defer { IOObjectRelease(object) }
            guard let stats = registry(object, "Statistics") as? [String: Any],
                  let read = stats["Bytes (Read)"] as? NSNumber,
                  let write = stats["Bytes (Write)"] as? NSNumber else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(object, &id) == KERN_SUCCESS else { continue }
            current[id] = (read.uint64Value, write.uint64Value)
            if let old = previousDisk[id], let dt {
                reads += counterDelta(read.uint64Value, old.0) / dt
                writes += counterDelta(write.uint64Value, old.1) / dt
            }
        }
        if !current.isEmpty, dt != nil { s.diskRead = reads; s.diskWrite = writes }
        previousDisk = current
    }
    private func readGPU(_ s: inout Sample) {
        for service in services("IOAccelerator") {
            defer { IOObjectRelease(service) }
            if let stats = registry(service, "PerformanceStatistics") as? [String: Any],
               let value = stats["Device Utilization %"] as? NSNumber {
                s.gpu = max(s.gpu ?? 0, min(100, max(0, value.doubleValue)))
            }
        }
    }
    private func readSensors(_ s: inout Sample, detailed: Bool) {
        s.smcAvailable = smc != 0
        s.sensorsComplete = detailed
        // Each SMC read is ~0.2 ms and there are ~70 CPU/GPU keys. Temperatures move slowly,
        // so with no panel open the summary is refreshed every 3 s; power and fans stay live.
        let now = ProcessInfo.processInfo.systemUptime
        if !detailed, let cached = summaryTemperatures, now - cached.time >= 0, now - cached.time < 3 {
            s.sensors = cached.values
        } else {
            for (key, name) in sensorKeys where detailed || name == "CPU" || name == "GPU" {
                guard let value = readSMC(key), value > 0, value < 130 else { continue }
                s.sensors.append(SensorValue(key: key, name: name, value: value, kind: "°C"))
            }
            summaryTemperatures = (now, s.sensors.filter { $0.name == "CPU" || $0.name == "GPU" })
        }
        s.cpuTemp = s.sensors.filter { $0.name == "CPU" }.map(\.value).max()
        s.gpuTemp = s.sensors.filter { $0.name == "GPU" }.map(\.value).max()
        if let watts = readSMC("PSTR"), watts > 0, watts < 1500 {
            s.watts = watts; s.powerSource = "SMC · PSTR"
        }
        let fans = Int(min(16, max(0, readSMC("FNum") ?? 0)))
        for i in 0..<fans {
            if let rpm = readSMC("F\(i)Ac"), rpm >= 0, rpm < 20000 {
                s.sensors.append(SensorValue(key: "F\(i)Ac", name: "风扇 \(i + 1)", value: rpm, kind: "RPM"))
                if fanRanges[i] == nil, let low = readSMC("F\(i)Mn"), let high = readSMC("F\(i)Mx"), high > low { fanRanges[i] = (low, high) }
                let range = fanRanges[i] ?? (0, max(rpm, 1))
                s.fans.append(FanReading(rpm: rpm, min: range.min, max: range.max))
            }
        }
    }
    private func readPower(_ s: inout Sample, detailed: Bool, now: TimeInterval) {
        guard powerCounters else { return }
        // Counters accumulate energy, so a 3 s interval gives the same average as three 1 s reads;
        // with no panel open, skip the IOReport round trip in between.
        var watts: [Double]
        if !detailed, let last = lastPower, now - last.time >= 0, now - last.time < 3 {
            watts = last.watts
        } else {
            var cpu = 0.0, gpu = 0.0, ane = 0.0
            let ok = mp_power_sample(&cpu, &gpu, &ane) == 1
            let interval = powerBaseline.map { now - $0 }
            powerBaseline = now
            // Never average a wakeup/reset gap into live rates.
            guard ok, let interval, interval > 0, interval < 30 else { lastPower = nil; return }
            watts = [cpu, gpu, ane].map { $0 / interval }
            guard watts.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 500 }) else { lastPower = nil; return }
            lastPower = (now, watts)
        }
        s.cpuPower = watts[0]; s.gpuPower = watts[1]; s.anePower = watts[2]
        for (value, name, key) in zip(watts, [("CPU 功耗", "CLPC.CPU"), ("GPU 功耗", "CLPC.GPU"), ("神经网络引擎功耗", "CLPC.ANE")]).map({ ($0, $1.0, $1.1) }) {
            s.sensors.append(SensorValue(key: key, name: name, value: value, kind: "W"))
        }
    }
    private func readProcesses(_ s: inout Sample, dt: Double?) {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return }
        var current: [pid_t: UInt64] = [:], all: [ProcessUsage] = []
        for pid in pids.prefix(min(count, pids.count)) where pid > 0 {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard result == 0 else { s.processesHidden += 1; continue }
            // rusage times are Mach ticks on Apple Silicon.
            let ticks = info.ri_user_time &+ info.ri_system_time
            current[pid] = ticks
            var cpu: Double?
            if let dt, let old = previousProcess[pid], ticks >= old { cpu = Double(ticks - old) * ticksToNanoseconds / (dt * 1e9) * 100 }
            let name = processNames[pid] ?? Self.processName(pid)
            processNames[pid] = name
            all.append(ProcessUsage(pid: pid, name: name, cpu: cpu, memory: Double(info.ri_phys_footprint)))
        }
        processNames = processNames.filter { current[$0.key] != nil }
        previousProcess = current
        let byCPU = all.sorted { ($0.cpu ?? -1) > ($1.cpu ?? -1) }.prefix(10)
        let byMemory = all.sorted { $0.memory > $1.memory }.prefix(10)
        var seen = Set<pid_t>()
        s.processes = (byCPU + byMemory).filter { seen.insert($0.pid).inserted }
    }
    private static func processName(_ pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let name = URL(fileURLWithPath: String(cString: path)).lastPathComponent
            if !name.isEmpty { return name }
        }
        var short = [CChar](repeating: 0, count: 64)
        return proc_name(pid, &short, UInt32(short.count)) > 0 ? String(cString: short) : "进程 \(pid)"
    }
    private func readBattery(_ s: inout Sample) {
        for object in services("AppleSmartBattery") {
            defer { IOObjectRelease(object) }
            if let telemetry = registry(object, "PowerTelemetryData") as? [String: Any], s.watts == nil,
               let power = telemetry["SystemPowerIn"] as? NSNumber, power.doubleValue > 0 {
                s.watts = power.doubleValue / 1000; s.powerSource = "系统输入功率 · IORegistry"
            }
            guard (registry(object, "BatteryInstalled") as? Bool) == true else { continue }
            let current = (registry(object, "CurrentCapacity") as? NSNumber)?.doubleValue ?? 0
            let max = (registry(object, "MaxCapacity") as? NSNumber)?.doubleValue ?? 0
            if max > 0 { s.batteryPercent = min(100, current / max * 100) }
            s.charging = (registry(object, "IsCharging") as? Bool) ?? false
            s.batteryCycles = (registry(object, "CycleCount") as? NSNumber)?.intValue
            s.batteryDesignCycles = (registry(object, "DesignCycleCount9C") as? NSNumber)?.intValue
            // On Apple Silicon MaxCapacity is a percentage; the mAh figures live in BatteryData.
            // Nominal (not the temperature-compensated FullCharge) capacity matches System Settings.
            if let data = registry(object, "BatteryData") as? [String: Any],
               let design = (data["DesignCapacity"] as? NSNumber)?.doubleValue, design > 0,
               let full = ((data["NominalChargeCapacity"] ?? data["FullChargeCapacity"]) as? NSNumber)?.doubleValue, full > 0 {
                s.batteryHealth = min(100, full / design * 100)
                s.batteryCapacity = (full, design)
            }
        }
    }
}

enum Format {
    static func number(_ value: Double?, suffix: String = "", decimals: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.*f", decimals, value) + suffix
    }
    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var n = max(0, value), index = 0
        while n >= 1024 && index < units.count - 1 { n /= 1024; index += 1 }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", n, units[index])
    }
    static func rate(_ value: Double?) -> String { value.map { bytes($0) + "/s" } ?? "—" }
    static func uptime(_ value: Double) -> String {
        let minutes = Int(value / 60)
        return minutes >= 1440 ? "\(minutes / 1440) 天 \(minutes / 60 % 24) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}
