// bmapprobe.swift — find the BMAP RFCOMM channel on Bose headphones (macOS)
//
// Build:  swiftc -O bmapprobe.swift -o bmapprobe -framework IOBluetooth
// Usage:
//   ./bmapprobe list                      paired devices + addresses
//   ./bmapprobe services <addr>           dump SDP records (name, UUIDs, RFCOMM channel)
//   ./bmapprobe probe <addr> [1-30]       try channels, send a BMAP "get" on each
//   ./bmapprobe send <addr> <ch> <hex>    send raw bytes, print replies for 3s
//
// First run: macOS will ask to allow Bluetooth for your terminal app.
// Quit the official Bose app / disconnect the headphones from your phone first.
//
// BMAP frame (from memory of public QC35 reverse engineering; verify against
// bosectl NOTES.md): [block][function][operator | port<<4][length][payload...]
// Operators: 0 SET, 1 GET, 2 SETGET, 3 STATUS, 4 ERROR, 5 START, 6 RESULT, 7 PROCESSING

import Foundation
import IOBluetooth

// MARK: - Helpers

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }

func parseHex(_ parts: [String]) -> [UInt8] {
    let s = parts.joined().filter { $0.isHexDigit }
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        guard let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex),
              let b = UInt8(s[i..<j], radix: 16) else { break }
        out.append(b); i = j
    }
    return out
}

func pump(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func fmtUUID(_ d: Data) -> String {
    guard d.count == 16 else { return hex(d) }
    let h = d.map { String(format: "%02x", $0) }.joined()
    let p = [0, 8, 12, 16, 20, 32].map { h.index(h.startIndex, offsetBy: $0) }
    return (0..<5).map { String(h[p[$0]..<p[$0 + 1]]) }.joined(separator: "-")
}

func device(_ addr: String) -> IOBluetoothDevice? {
    IOBluetoothDevice(addressString: addr.replacingOccurrences(of: ":", with: "-"))
}

// MARK: - RFCOMM listener

final class Listener: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var received = Data()
    var verbose = true
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let d = Data(bytes: dataPointer, count: dataLength)
        received.append(d)
        if verbose { print("  <- \(hex(d))") }
    }
    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        print("  (channel closed by remote)")
    }
}

func openChannel(_ dev: IOBluetoothDevice, _ id: UInt8, _ l: Listener) -> IOBluetoothRFCOMMChannel? {
    if !dev.isConnected() { _ = dev.openConnection() }
    var ch: IOBluetoothRFCOMMChannel?
    let r = dev.openRFCOMMChannelSync(&ch, withChannelID: id, delegate: l)
    return r == kIOReturnSuccess ? ch : nil
}

func write(_ ch: IOBluetoothRFCOMMChannel, _ bytes: [UInt8]) {
    var b = bytes
    let r = ch.writeSync(&b, length: UInt16(b.count))
    print("  -> \(hex(Data(bytes))) \(r == kIOReturnSuccess ? "" : "(write failed \(r))")")
}

// MARK: - Commands

func cmdList() {
    let devs = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    for d in devs {
        print("\(d.addressString ?? "?")  \(d.name ?? "?")  \(d.isConnected() ? "[connected]" : "")")
    }
}

func cmdServices(_ addr: String) {
    guard let dev = device(addr) else { return print("bad address") }
    if !dev.isConnected() { _ = dev.openConnection() }
    _ = dev.performSDPQuery(nil)
    pump(4)
    let recs = (dev.services as? [IOBluetoothSDPServiceRecord]) ?? []
    if recs.isEmpty { print("no SDP records (is the device connected?)") }
    for rec in recs {
        var ch: BluetoothRFCOMMChannelID = 0
        let hasCh = rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess
        print("• \(rec.getServiceName() ?? "(unnamed)")  rfcomm=\(hasCh ? String(ch) : "-")")
        if let el = rec.getAttributeDataElement(0x0001),
           let arr = el.getArrayValue() as? [IOBluetoothSDPDataElement] {
            for e in arr {
                if let u = e.getUUIDValue() { print("    uuid \(fmtUUID(Data(referencing: u)))") }
            }
        }
    }
    print("\nLook for a 128-bit custom UUID with an RFCOMM channel; that's likely BMAP.")
}

func cmdProbe(_ addr: String, _ only: Int?) {
    guard let dev = device(addr) else { return print("bad address") }
    let range = only.map { [UInt8($0)] } ?? Array(1...30)
    // BMAP "get BMAP version" (block 0, function 1, GET, len 0) — from memory, verify.
    let probe: [UInt8] = [0x00, 0x01, 0x01, 0x00]
    for id in range {
        print("channel \(id)…")
        let l = Listener()
        guard let ch = openChannel(dev, id, l) else { print("  open failed"); continue }
        pump(0.5)                 // some devices talk first
        write(ch, probe)
        pump(1.5)
        print(l.received.isEmpty ? "  no reply" : "  *** got data — candidate BMAP channel ***")
        _ = ch.close()
        pump(0.3)
    }
}

func cmdSend(_ addr: String, _ chId: Int, _ hexParts: [String]) {
    guard let dev = device(addr) else { return print("bad address") }
    let l = Listener()
    guard let ch = openChannel(dev, UInt8(chId), l) else { return print("open failed") }
    pump(0.5)
    write(ch, parseHex(hexParts))
    pump(3)
    _ = ch.close()
}

// Sends GET (operator 1, length 0) to every block/function pair on one open
// channel. Read-only. Prints replies that are not the most common error code,
// so supported functions stand out without relying on my remembered error table.
func cmdSweep(_ addr: String, _ chId: Int, _ maxBlock: Int, _ maxFunc: Int) {
    guard let dev = device(addr) else { return print("bad address") }
    let l = Listener()
    l.verbose = false
    guard let ch = openChannel(dev, UInt8(chId), l) else { return print("open failed") }
    pump(0.5)
    struct R { let b: Int; let f: Int; let op: UInt8; let payload: [UInt8] }
    var results: [R] = []
    outer: for b in 0...maxBlock {
        for f in 0...maxFunc {
            if !ch.isOpen() { print("channel closed at \(b).\(f)"); break outer }
            l.received = Data()
            var pkt: [UInt8] = [UInt8(b), UInt8(f), 0x01, 0x00]
            _ = ch.writeSync(&pkt, length: 4)
            pump(0.15)
            let d = [UInt8](l.received)
            guard d.count >= 4 else { continue }
            let len = Int(d[3])
            let payload = Array(d[4..<min(d.count, 4 + len)])
            results.append(R(b: b, f: f, op: d[2] & 0x0f, payload: payload))
        }
        print("block \(b) done")
    }
    _ = ch.close()
    var counts: [UInt8: Int] = [:]
    for r in results where r.op == 4 { counts[r.payload.first ?? 0, default: 0] += 1 }
    let common = counts.max { $0.value < $1.value }?.key
    print("\nerror code counts: \(counts)  (hiding code \(common.map { String($0) } ?? "-"))\n")
    for r in results {
        if r.op == 4 && r.payload.first == common { continue }
        let kind = r.op == 4 ? "ERROR " : (r.op == 3 ? "STATUS" : "op\(r.op)   ")
        print(String(format: "%02x.%02x  ", r.b, r.f) + kind + " " + hex(Data(r.payload)))
    }
}

func parseFrames(_ d: [UInt8]) -> [(b: UInt8, f: UInt8, op: UInt8, payload: [UInt8])] {
    var out: [(b: UInt8, f: UInt8, op: UInt8, payload: [UInt8])] = []
    var i = 0
    while i + 4 <= d.count {
        let len = Int(d[i + 3])
        guard i + 4 + len <= d.count else { break }
        out.append((d[i], d[i + 1], d[i + 2] & 0x0f, Array(d[(i + 4)..<(i + 4 + len)])))
        i += 4 + len
    }
    return out
}

// Addresses that returned short STATUS payloads in the first QC Headphones sweep.
let defaultWatch: [String] = [
    "01.03", "01.04", "01.05", "01.07", "01.09", "01.0a", "01.0b", "01.0c", "01.0e",
    "02.05", "02.0a", "02.0f", "02.11",
    "03.01", "03.02", "03.04", "03.06", "03.07", "03.0a", "03.0d",
    "04.01", "04.0e", "05.03", "05.04", "05.05", "05.07", "05.0d",
    "07.04", "07.07", "07.08", "08.07", "09.02", "12.01", "12.0b", "12.11", "17.0b", "17.18",
    "19.02", "19.03", "19.04", "19.05", "19.06", "19.07", "19.08", "19.09", "19.0a", "19.0b",
    "19.0c", "19.0d", "19.0e", "19.0f", "19.10", "19.11", "19.12", "19.13", "19.14", "19.15",
    "19.16", "19.17", "19.18", "19.19", "19.1a", "19.1b", "19.1c", "19.1f",
    "1f.02", "1f.03", "1f.04", "1f.05", "1f.07", "1f.08",
]

// Polls GET on each address in a loop and prints only values that change.
// Run it, then toggle Quiet/Aware on the headphones and see what moves.
func cmdWatch(_ addr: String, _ chId: Int, _ list: [String]) {
    guard let dev = device(addr) else { return print("bad address") }
    let l = Listener()
    l.verbose = false
    guard let ch = openChannel(dev, UInt8(chId), l) else { return print("open failed") }
    pump(0.5)
    let targets = (list.isEmpty ? defaultWatch : list).compactMap { s -> (UInt8, UInt8)? in
        let p = s.split(separator: ".")
        guard p.count == 2, let b = UInt8(p[0], radix: 16), let f = UInt8(p[1], radix: 16) else { return nil }
        return (b, f)
    }
    var last: [String: [UInt8]] = [:]
    var first = true
    print("watching \(targets.count) addresses. Toggle the headphones when you see 'baseline captured' (Ctrl-C to stop)")
    while ch.isOpen() {
        for (b, f) in targets {
            l.received = Data()
            var pkt: [UInt8] = [b, f, 0x01, 0x00]
            _ = ch.writeSync(&pkt, length: 4)
            pump(0.12)
            guard let r = parseFrames([UInt8](l.received)).first(where: { $0.b == b && $0.f == f && $0.op == 3 }) else { continue }
            let key = String(format: "%02x.%02x", b, f)
            if let old = last[key], old != r.payload {
                print("\(key)  \(hex(Data(old))) -> \(hex(Data(r.payload)))")
            }
            last[key] = r.payload
        }
        if first { print("baseline captured"); first = false }
        pump(0.3)
    }
    print("channel closed")
}

// MARK: - Main

let a = CommandLine.arguments
switch (a.count > 1 ? a[1] : "") {
case "list": cmdList()
case "services" where a.count > 2: cmdServices(a[2])
case "probe" where a.count > 2: cmdProbe(a[2], a.count > 3 ? Int(a[3]) : nil)
case "send" where a.count > 4: cmdSend(a[2], Int(a[3]) ?? 0, Array(a[4...]))
case "sweep" where a.count > 3:
    cmdSweep(a[2], Int(a[3]) ?? 0, a.count > 4 ? Int(a[4]) ?? 0x20 : 0x20, a.count > 5 ? Int(a[5]) ?? 0x1f : 0x1f)
case "watch" where a.count > 3:
    cmdWatch(a[2], Int(a[3]) ?? 0, Array(a.dropFirst(4)))
default:
    print("usage: bmapprobe list | services <addr> | probe <addr> [ch] | send <addr> <ch> <hex> | sweep <addr> <ch> [maxBlock] [maxFunc] | watch <addr> <ch> [b.f ...]")
}