import Foundation

// MacPulse fan helper. Installed only when the user turns on fan control, it runs as root
// because AppleSMC refuses writes from ordinary processes. It accepts four commands, one per
// connection, on a socket only the installing user can open:
//   status            → ok version=1 fans=N f0=actual,min,max,target,mode …
//   auto              → every fan back to system control
//   set <fan> <rpm>   → manual target, clamped to the fan's own min…max
//   ping              → keeps manual mode alive
// Manual mode falls back to system control after 45 s without a command (MacPulse quit or
// crashed), and on SIGTERM. Fan sequence follows Stats (github.com/exelban/stats, MIT):
// M5 and later take the mode key directly; M1–M4 first need Ftst = 1.

let helperVersion = 1
var socketPath = "/var/run/local.macpulse.fanhelper.sock"
var owner: uid_t = 0
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    if argument == "--owner", let value = arguments.next().flatMap({ uid_t($0) }) { owner = value }
    if argument == "--socket", let value = arguments.next() { socketPath = value }
}

let smc = mp_smc_open()
let queue = DispatchQueue(label: "local.macpulse.fanhelper")
var manualSince: Date?
var lastContact = Date()

func exists(_ key: String) -> Bool {
    var type: UInt32 = 0, size: UInt32 = 0
    return mp_smc_info(smc, key, &type, &size) != 0
}
func read(_ key: String) -> Double? {
    var value = 0.0
    return mp_smc_read(smc, key, &value) != 0 ? value : nil
}
func write(_ key: String, _ bytes: [UInt8], attempts: Int = 10, delay: UInt32 = 50_000) -> Bool {
    for attempt in 0..<attempts {
        if mp_smc_write(smc, key, bytes, UInt32(bytes.count)) != 0 { return true }
        if attempt < attempts - 1 { usleep(delay) }
    }
    return false
}
func floatBytes(_ value: Float) -> [UInt8] { withUnsafeBytes(of: value) { Array($0) } }
func fanCount() -> Int { Int(read("FNum") ?? 0) }
func modeKey(_ fan: Int) -> String { exists("F\(fan)md") ? "F\(fan)md" : "F\(fan)Md" }

func setAuto() -> Bool {
    var ok = true
    for fan in 0..<fanCount() {
        if read(modeKey(fan)) != 0 { ok = write(modeKey(fan), [0]) && ok }
        _ = write("F\(fan)Tg", floatBytes(0))
    }
    if exists("Ftst"), read("Ftst") == 1 { ok = write("Ftst", [0]) && ok }
    manualSince = nil
    return ok
}

func unlock(_ fan: Int) -> Bool {
    if write(modeKey(fan), [1], attempts: 1) { return true }
    guard exists("Ftst") else { return false }
    if read("Ftst") != 1 {
        guard write("Ftst", [1], attempts: 100) else { return false }
        // thermalmonitord needs a moment to yield.
        sleep(3)
    }
    return write(modeKey(fan), [1], attempts: 300, delay: 100_000)
}

func setRPM(_ fan: Int, _ requested: Double) -> String {
    guard (0..<fanCount()).contains(fan), let low = read("F\(fan)Mn"), let high = read("F\(fan)Mx"), high > low else { return "error no-fan" }
    let rpm = min(high, max(low, requested))
    if read(modeKey(fan)) != 1 { guard unlock(fan) else { return "error unlock" } }
    guard write("F\(fan)Tg", floatBytes(Float(rpm))) else { return "error write" }
    manualSince = manualSince ?? Date()
    return "ok rpm=\(Int(rpm))"
}

func status() -> String {
    var parts = ["ok", "version=\(helperVersion)", "fans=\(fanCount())", "manual=\(manualSince == nil ? 0 : 1)"]
    for fan in 0..<fanCount() {
        let values = ["Ac", "Mn", "Mx", "Tg"].map { Int(read("F\(fan)\($0)") ?? -1) } + [Int(read(modeKey(fan)) ?? -1)]
        parts.append("f\(fan)=" + values.map(String.init).joined(separator: ","))
    }
    return parts.joined(separator: " ")
}

func handle(_ line: String) -> String {
    let words = line.split(separator: " ").map(String.init)
    lastContact = Date()
    switch words.first {
    case "status": return status()
    case "ping": return "ok"
    case "auto": return setAuto() ? "ok" : "error write"
    case "set" where words.count == 3:
        guard let fan = Int(words[1]), let rpm = Double(words[2]) else { return "error arguments" }
        return setRPM(fan, rpm)
    default: return "error unknown"
    }
}

// MARK: Socket

guard smc != 0 else { fputs("AppleSMC unavailable\n", stderr); exit(1) }
unlink(socketPath)
let server = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    let bytes = Array(socketPath.utf8.prefix(buffer.count - 1))
    buffer.copyBytes(from: bytes + [0])
}
let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard server >= 0, bound == 0, listen(server, 4) == 0 else { fputs("socket failed\n", stderr); exit(1) }
// Only the installing user (and root) may connect.
if owner != 0, let entry = getpwuid(owner) { chown(socketPath, owner, entry.pointee.pw_gid) }
chmod(socketPath, 0o600)

Thread {
    while true {
        let client = accept(server, nil, nil)
        guard client >= 0 else { continue }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = recv(client, &buffer, buffer.count, 0)
        if count > 0 {
            let line = String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = queue.sync { handle(line) } + "\n"
            _ = reply.utf8CString.withUnsafeBufferPointer { send(client, $0.baseAddress, reply.utf8.count, 0) }
        }
        close(client)
    }
}.start()

let watchdog = DispatchSource.makeTimerSource(queue: queue)
watchdog.schedule(deadline: .now() + 5, repeating: 5)
watchdog.setEventHandler {
    if manualSince != nil, Date().timeIntervalSince(lastContact) > 45 { _ = setAuto() }
}
watchdog.resume()

signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
terminate.setEventHandler { _ = setAuto(); unlink(socketPath); exit(0) }
terminate.resume()

dispatchMain()
