// VIA raw HID probe: sends each argument as one 32-byte command to the keyboard's 0xFF60/0x61 interface
// and prints the first 32 bytes of the reply.
//
//   swiftc -O via-probe.swift -o via-probe
//   ./via-probe 1a86 fc16 01 11 04000000      # protocol version, layer count, layer 0 key (0,0)
//
// It sends whatever you give it. Stick to read commands (01 11 0c 0d 0e 12 14 08); 0x02 stalls the BNK16,
// and 05 07 09 0f 15 write to the board. Never send 06 0a 0b 10.
import Foundation
import IOKit.hid
let args = CommandLine.arguments
let vid = Int(args[1], radix: 16)!, pid = Int(args[2], radix: 16)!
let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vid, kIOHIDProductIDKey: pid, kIOHIDPrimaryUsagePageKey: 0xFF60, kIOHIDPrimaryUsageKey: 0x61] as CFDictionary)
IOHIDManagerOpen(manager, 0)
guard let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else { print("no device"); exit(1) }
IOHIDDeviceOpen(device, 0)
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
var reply: [UInt8]? = nil
let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { _, _, _, _, _, r, n in reply = Array(UnsafeBufferPointer(start: r, count: n)) }, nil)
for cmd in args.dropFirst(3) {
    var bytes = stride(from: 0, to: cmd.count, by: 2).map { UInt8(cmd.dropFirst($0).prefix(2), radix: 16)! }
    bytes += Array(repeating: 0, count: 32 - bytes.count)
    reply = nil
    let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &bytes, 32)
    let end = Date().addingTimeInterval(0.4)
    while r == kIOReturnSuccess && reply == nil && Date() < end { CFRunLoopRunInMode(.defaultMode, 0.02, true) }
    print(cmd, r == kIOReturnSuccess ? (reply.map { $0.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "no reply") : "send err \(r)")
}
