import Foundation
import GPSCore

// gpsbridge – headless tool that makes gpsd data usable on macOS.

let usage = """
gpsbridge – makes GPS data available to macOS programs

Usage: gpsbridge [options]

  --gpsd HOST[:PORT]     gpsd address (default 127.0.0.1:2947)
  --start-gpsd DEVICE    start gpsd itself, e.g. /dev/cu.usbserial-110
  --serial DEVICE        without gpsd: read an NMEA receiver directly
  --baud N               baud rate for --serial (default: auto-detect)
  --nmea PORT            NMEA-0183 TCP server (e.g. 10110)
  --lan                  expose NMEA/HTTP servers on the LAN (default: localhost only)
  --pty PATH             create a virtual serial port (e.g. /tmp/gps-nmea)
  --http PORT            HTTP/JSON API (e.g. 8947): /position /geojson /nmea /tpv /sky
  --json FILE            continuously write the current position as JSON
  --gpx DIRECTORY        record the track as GPX
  --stdout               write NMEA to stdout
  --once                 print one position as JSON and exit
  --list-devices         list serial devices
  -h, --help             show this help

Examples:
  gpsbridge --serial /dev/cu.usbmodem1101 --nmea 10110 --http 8947
  gpsbridge --start-gpsd /dev/cu.usbmodem1101 --nmea 10110 --pty /tmp/gps-nmea --http 8947
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("gpsbridge: \(msg)\n".utf8))
    exit(1)
}

func log(_ msg: String) {
    FileHandle.standardError.write(Data("[gpsbridge] \(msg)\n".utf8))
}

var host = "127.0.0.1", port: UInt16 = 2947
var startDevice: String?
var serialDevice: String?, baud: Int?
var nmeaPort: UInt16?, httpPort: UInt16?
var lan = false, toStdout = false, once = false
var ptyPath: String?, jsonPath: String?, gpxDir: String?

var args = Array(CommandLine.arguments.dropFirst())
func next(_ flag: String) -> String {
    guard !args.isEmpty else { fail("\(flag) requires a value") }
    return args.removeFirst()
}
func portValue(_ s: String, _ flag: String) -> UInt16 {
    guard let p = UInt16(s), p > 0 else { fail("invalid port for \(flag): \(s)") }
    return p
}

while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--gpsd":
        let v = next(a).split(separator: ":")
        host = String(v[0])
        if v.count > 1 { port = portValue(String(v[1]), a) }
    case "--start-gpsd": startDevice = next(a)
    case "--serial": serialDevice = next(a)
    case "--baud":
        let v = next(a)
        guard let b = Int(v), b > 0 else { fail("invalid baud rate: \(v)") }
        baud = b
    case "--nmea": nmeaPort = portValue(next(a), a)
    case "--http": httpPort = portValue(next(a), a)
    case "--lan": lan = true
    case "--pty": ptyPath = next(a)
    case "--json": jsonPath = next(a)
    case "--gpx": gpxDir = next(a)
    case "--stdout": toStdout = true
    case "--once": once = true
    case "--list-devices":
        GPSDController.serialDevices().forEach { print($0) }
        exit(0)
    case "-h", "--help": print(usage); exit(0)
    default: fail("unknown option \(a)\n\n\(usage)")
    }
}

if serialDevice != nil && startDevice != nil { fail("--serial and --start-gpsd are mutually exclusive") }

let bridge = GPSBridge()
let controller = GPSDController()
let queue = DispatchQueue(label: "gpsbridge")
controller.callbackQueue = queue
controller.onOutput = { log("gpsd: \($0)") }
controller.onExit = { code in log("gpsd exited (\(code))") }

if let dev = startDevice {
    if GPSDController.isListening(port: port) {
        log("gpsd is already running on port \(port) – not starting a second one")
    } else {
        do { try controller.start(device: dev, port: port) } catch { fail(error.localizedDescription) }
    }
}

do {
    if let p = nmeaPort {
        bridge.nmeaServer.onClientsChanged = { log("NMEA-Clients: \($0)") }
        try bridge.nmeaServer.start(port: p, lanAccess: lan)
        log("NMEA-TCP: \(lan ? "0.0.0.0" : "127.0.0.1"):\(p)")
    }
    if let p = httpPort {
        try bridge.http.start(port: p, lanAccess: lan)
        log("HTTP: http://127.0.0.1:\(p)/position")
    }
    if let path = ptyPath {
        try bridge.pty.start(linkPath: path)
        log("Serial port: \(path) → \(bridge.pty.deviceName ?? "?")")
    }
    if let path = jsonPath {
        bridge.jsonFileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        log("JSON file: \(path)")
    }
    if let dir = gpxDir {
        let url = try bridge.gpx.start(directory: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        log("GPX: \(url.path)")
    }
} catch {
    fail(error.localizedDescription)
}

var onSKY: (SKY) -> Void = { bridge.ingest(sky: $0) }
var onTPV: (TPV) -> Void = { tpv in
    bridge.ingest(tpv: tpv)
    if toStdout { bridge.nmeaSentences.forEach { print($0, terminator: "") }; fflush(stdout) }
    if once, tpv.hasFix {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(bridge.position) { print(String(decoding: data, as: UTF8.self)) }
        exit(0)
    }
}

func shutdown(_ sig: Int32) {
    queue.async {
        if let url = bridge.gpx.stop() { log("GPX saved: \(url.path)") }
        reader.stop()
        bridge.stopAll()
        if controller.isManagedRunning { try? controller.stop() }
        exit(0)
    }
}
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: queue)
    s.setEventHandler { shutdown(sig) }
    s.resume()
    return s
}

if !(nmeaPort != nil || httpPort != nil || ptyPath != nil || jsonPath != nil || gpxDir != nil || toStdout || once) {
    log("No output selected – see --help. Logging positions.")
    onTPV = { tpv in
        bridge.ingest(tpv: tpv)
        let p = bridge.position
        log("\(tpv.modeDescription): \(p.latitude.map { String(format: "%.7f", $0) } ?? "—"), \(p.longitude.map { String(format: "%.7f", $0) } ?? "—")")
    }
}

// Data source: gpsd or the receiver directly
let client = GPSDClient(host: host, port: port, callbackQueue: queue)
let reader = SerialNMEAReader(callbackQueue: queue)
if let dev = serialDevice {
    var last: SerialNMEAReader.State?
    reader.onState = { state in
        if state != last { log("\(dev): \(state.description)") }
        last = state
    }
    reader.onSKY = { onSKY($0) }
    reader.onTPV = { onTPV($0) }
    reader.start(path: dev, baud: baud)
} else {
    var last: GPSDClient.State?
    client.onState = { state in
        if state != last { log("gpsd \(host):\(port): \(state.description)") }
        last = state
    }
    client.onSKY = { onSKY($0) }
    client.onTPV = { onTPV($0) }
    client.onError = { log("gpsd error: \($0)") }
    client.start()
}

withExtendedLifetime((sources, client, reader)) { dispatchMain() }
