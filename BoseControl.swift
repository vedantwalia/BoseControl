// BoseControl — macOS menu bar switcher for Bose QuietComfort Headphones (2023)
// Protocol findings (from probing this headset):
//   RFCOMM channel 8 speaks BMAP.   Frame: [block][function][operator][length][payload]
//   Read mode:   1f 03 01 00        -> 1f 03 03 01 <index>
//   Set mode:    1f 03 05 01 <idx>  (START; headset replies PROCESSING, then applies)
//   Battery:     02 02 01 00        -> 02 02 03 04 <percent> ...

import SwiftUI
import IOBluetooth

// ---- Edit these ----
let deviceAddress = "68-f2-1f-45-c2-71"
let bmapChannel: BluetoothRFCOMMChannelID = 8
let modeNames = ["Quiet", "Aware", "Commute", "Home"]   // index = value of 1f.03
// --------------------

struct Frame { let block: UInt8; let function: UInt8; let op: UInt8; let payload: [UInt8] }

func parseFrames(_ buf: inout [UInt8]) -> [Frame] {
    var out: [Frame] = []
    while buf.count >= 4 {
        let len = Int(buf[3])
        if buf.count < 4 + len { break }
        out.append(Frame(block: buf[0], function: buf[1], op: buf[2] & 0x0f,
                         payload: Array(buf[4..<(4 + len)])))
        buf.removeFirst(4 + len)
    }
    return out
}

final class BoseLink: NSObject, ObservableObject, IOBluetoothRFCOMMChannelDelegate {
    @Published var mode: Int? = nil
    @Published var battery: Int? = nil
    @Published var connected = false

    private var channel: IOBluetoothRFCOMMChannel?
    private var opening = false
    private var buffer: [UInt8] = []
    private var timer: Timer?

    override init() {
        super.init()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    // Poll while connected; otherwise reconnect if the headset is already
    // connected to this Mac (we never force a connection away from your phone).
    private func tick() {
        if let ch = channel, ch.isOpen() { query(); return }
        setDisconnected()
        guard !opening else { return }
        guard let dev = IOBluetoothDevice(addressString: deviceAddress) else {
            note("no device for address \(deviceAddress)"); return
        }
        guard dev.isConnected() else {
            note("headset not connected to this Mac"); return
        }
        opening = true
        var ch: IOBluetoothRFCOMMChannel?
        let r = dev.openRFCOMMChannelAsync(&ch, withChannelID: bmapChannel, delegate: self)
        note("open async returned \(r)")
        if r == kIOReturnSuccess {
            channel = ch
        } else {
            opening = false
        }
    }

    // Logs only when the message changes, so `log stream` stays readable.
    private var lastNote = ""
    private func note(_ s: String) {
        if s != lastNote { lastNote = s; NSLog("BoseControl: %@", s) }
    }

    private func setDisconnected() {
        if connected || mode != nil || battery != nil {
            connected = false; mode = nil; battery = nil
        }
    }

    private func send(_ bytes: [UInt8]) {
        guard let ch = channel, ch.isOpen() else { return }
        var b = bytes
        _ = ch.writeSync(&b, length: UInt16(b.count))
    }

    private func query() {
        send([0x1f, 0x03, 0x01, 0x00])   // mode
        send([0x02, 0x02, 0x01, 0x00])   // battery
    }

    func setMode(_ index: Int) {
        send([0x1f, 0x03, 0x05, 0x01, UInt8(index)])
        mode = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.query() }
    }

    private func handle(_ f: Frame) {
        guard f.op == 3, let v = f.payload.first else { return }   // STATUS only
        if f.block == 0x1f && f.function == 0x03 { mode = Int(v) }
        if f.block == 0x02 && f.function == 0x02 { battery = Int(v) }
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        opening = false
        note("open complete, status \(error)")
        if error == kIOReturnSuccess {
            channel = rfcommChannel
            buffer = []
            connected = true
            query()
        } else {
            channel = nil
        }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        buffer.append(contentsOf: UnsafeBufferPointer(
            start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength))
        for f in parseFrames(&buffer) { handle(f) }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        note("channel closed by remote")
        channel = nil
        setDisconnected()
    }
}

@main
struct BoseControlApp: App {
    @StateObject private var link = BoseLink()

    var body: some Scene {
        MenuBarExtra {
            Text(link.connected ? "QuietComfort Headphones" : "Not connected")
            Divider()
            ForEach(modeNames.indices, id: \.self) { i in
                Button {
                    link.setMode(i)
                } label: {
                    if link.mode == i {
                        Label(modeNames[i], systemImage: "checkmark")
                    } else {
                        Text(modeNames[i])
                    }
                }
            }
            .disabled(!link.connected)
            if let m = link.mode, m >= modeNames.count {
                Text("Mode \(m)")
            }
            Divider()
            if let b = link.battery { Text("Battery \(b)%") }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "headphones")
        }
    }
}