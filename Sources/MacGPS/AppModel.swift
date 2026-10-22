import AppKit
import Foundation
import GPSCore
import Observation

enum SourceMode: String, CaseIterable, Identifiable {
    case gpsd, direct
    var id: String { rawValue }
    var title: String { self == .gpsd ? "gpsd" : "Direct" }
}

@Observable
@MainActor
final class AppModel {
    // MARK: Live data
    var tpv = TPV()
    var sky = SKY()
    var connection: GPSDClient.State = .disconnected
    var gpsdVersion: String?
    var activeDevices: [GPSDDevice] = []
    var log: [String] = []
    var lastUpdate: Date?

    var satellites: [Satellite] {
        (sky.satellites ?? []).sorted { ($0.isUsed ? 0 : 1, $0.gnssName, $0.prn) < ($1.isUsed ? 0 : 1, $1.gnssName, $1.prn) }
    }

    // MARK: Data source
    var source: SourceMode { didSet { defaults.set(source.rawValue, forKey: "source"); sourceChanged(from: oldValue) } }
    /// 0 = automatic detection
    var baudRate: Int { didSet { defaults.set(baudRate, forKey: "baudRate") } }
    var directState: SerialNMEAReader.State = .stopped

    var isRunning: Bool { source == .gpsd ? gpsdRunning : directState.isActive }
    var isConnected: Bool { source == .gpsd ? connection == .connected : directState.isReading }
    var statusText: String {
        guard isConnected else { return source == .gpsd ? connection.description : directState.description }
        return tpv.mode == nil ? "Waiting for data…" : tpv.modeDescription
    }
    var statusDetail: String? {
        switch source {
        case .gpsd:
            guard isConnected, let v = gpsdVersion else { return nil }
            return "gpsd \(v)\(activeDevices.first?.path.map { " · \($0)" } ?? "")"
        case .direct:
            guard case .reading(let baud) = directState else { return nil }
            return "Direct · \(baud) baud · \(selectedDevice)"
        }
    }

    // MARK: gpsd control
    var gpsdRunning = false
    var gpsdBusy = false
    var serialDevices: [String] = []
    var selectedDevice: String { didSet { defaults.set(selectedDevice, forKey: "device") } }
    var gpsdPathOverride: String { didSet { defaults.set(gpsdPathOverride, forKey: "gpsdPath") } }
    var gpsdLAN: Bool { didSet { defaults.set(gpsdLAN, forKey: "gpsdLAN") } }
    var gpsdFound: Bool { GPSDController.findGPSD(customPath: gpsdPathOverride) != nil }
    var alertMessage: String?

    // MARK: Bridge settings
    var nmeaEnabled: Bool { didSet { defaults.set(nmeaEnabled, forKey: "nmeaEnabled"); applyNMEA() } }
    var nmeaPort: Int { didSet { defaults.set(nmeaPort, forKey: "nmeaPort") } }
    var nmeaLAN: Bool { didSet { defaults.set(nmeaLAN, forKey: "nmeaLAN") } }
    var nmeaClients = 0

    var ptyEnabled: Bool { didSet { defaults.set(ptyEnabled, forKey: "ptyEnabled"); applyPTY() } }
    var ptyPath: String { didSet { defaults.set(ptyPath, forKey: "ptyPath") } }
    var ptyDevice: String?

    var httpEnabled: Bool { didSet { defaults.set(httpEnabled, forKey: "httpEnabled"); applyHTTP() } }
    var httpPort: Int { didSet { defaults.set(httpPort, forKey: "httpPort") } }

    var jsonEnabled: Bool { didSet { defaults.set(jsonEnabled, forKey: "jsonEnabled"); applyJSON() } }

    var gpxRecording = false
    var gpxPoints = 0
    var gpxURL: URL?

    let gpsdPort: UInt16 = 2947
    let bridge = GPSBridge()
    private let client: GPSDClient
    private let controller = GPSDController()
    private let reader = SerialNMEAReader()
    private let defaults = UserDefaults.standard
    private var pollTimer: Timer?

    init() {
        defaults.register(defaults: [
            "nmeaPort": 10110, "httpPort": 8947,
            "ptyPath": "/tmp/gps-nmea", "nmeaEnabled": false, "ptyEnabled": false,
            "httpEnabled": false, "jsonEnabled": false, "source": SourceMode.gpsd.rawValue, "baudRate": 0,
        ])
        source = SourceMode(rawValue: defaults.string(forKey: "source") ?? "") ?? .gpsd
        baudRate = defaults.integer(forKey: "baudRate")
        selectedDevice = defaults.string(forKey: "device") ?? ""
        gpsdPathOverride = defaults.string(forKey: "gpsdPath") ?? ""
        gpsdLAN = defaults.bool(forKey: "gpsdLAN")
        nmeaEnabled = defaults.bool(forKey: "nmeaEnabled")
        nmeaPort = defaults.integer(forKey: "nmeaPort")
        nmeaLAN = defaults.bool(forKey: "nmeaLAN")
        ptyEnabled = defaults.bool(forKey: "ptyEnabled")
        ptyPath = defaults.string(forKey: "ptyPath") ?? "/tmp/gps-nmea"
        httpEnabled = defaults.bool(forKey: "httpEnabled")
        httpPort = defaults.integer(forKey: "httpPort")
        jsonEnabled = defaults.bool(forKey: "jsonEnabled")
        client = GPSDClient(port: gpsdPort)

        wireUp()
        refreshDevices()
        if source == .gpsd { client.start() }
        applyNMEA(); applyPTY(); applyHTTP(); applyJSON()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    private func wireUp() {
        client.onState = { [weak self] state in
            guard let self else { return }
            if state != self.connection { self.append("gpsd client: \(state.description)") }
            self.connection = state
            if state != .connected { self.activeDevices = [] }
        }
        client.onTPV = { [weak self] in self?.receive(tpv: $0) }
        client.onSKY = { [weak self] in self?.receive(sky: $0) }
        reader.onTPV = { [weak self] in self?.receive(tpv: $0) }
        reader.onSKY = { [weak self] in self?.receive(sky: $0) }
        reader.onRaw = { [weak self] line in
            // Receiver messages such as antenna status or firmware version
            if line.dropFirst(3).hasPrefix("TXT,") {
                self?.append("Receiver: \(line.split(separator: ",").dropFirst(4).joined(separator: ",").split(separator: "*").first ?? "")")
            }
        }
        reader.onState = { [weak self] state in
            guard let self, state != self.directState else { return }
            self.directState = state
            self.append("Direct: \(state.description)")
            if case .failed = state, self.source == .direct,
               !FileManager.default.fileExists(atPath: self.selectedDevice) {
                self.followReplugged()
            }
        }
        client.onVersion = { [weak self] v in
            self?.gpsdVersion = v.release
            self?.append("gpsd \(v.release ?? "?") (protocol \(v.proto_major ?? 0).\(v.proto_minor ?? 0))")
        }
        client.onDevices = { [weak self] devices in
            self?.activeDevices = devices
            for d in devices { self?.append("Device: \(d.path ?? "?") \(d.driver ?? "") \(d.bps.map { "\($0) bps" } ?? "")") }
        }
        client.onError = { [weak self] msg in self?.append("gpsd error: \(msg)") }

        controller.onOutput = { [weak self] line in self?.append("gpsd: \(line)") }
        controller.onExit = { [weak self] code in
            self?.append("gpsd exited (status \(code))")
            self?.poll()
        }
        bridge.nmeaServer.onClientsChanged = { @Sendable [weak self] n in
            Task { @MainActor in self?.nmeaClients = n }
        }
        bridge.nmeaServer.onError = { @Sendable [weak self] msg in
            Task { @MainActor in self?.append(msg); self?.alertMessage = msg }
        }
        bridge.http.onError = { @Sendable [weak self] msg in
            Task { @MainActor in self?.append(msg); self?.alertMessage = msg }
        }
    }

    private func receive(tpv: TPV) {
        self.tpv = tpv
        lastUpdate = Date()
        bridge.ingest(tpv: tpv)
        if gpxRecording { gpxPoints = bridge.gpx.pointCount }
    }

    private func receive(sky: SKY) {
        self.sky = sky
        bridge.ingest(sky: sky)
    }

    private func sourceChanged(from old: SourceMode) {
        guard old != source else { return }
        tpv = TPV()
        sky = SKY()
        switch source {
        case .direct:
            client.stop()
            // A gpsd started by us would hold the receiver exclusively.
            if controller.isManagedRunning { try? controller.stop(); append("gpsd stopped (direct mode)") }
        case .gpsd:
            reader.stop()
            client.start()
        }
        append("Data source: \(source.title)")
    }

    /// A receiver plugged into another USB port gets a new /dev name.
    /// Follow it when exactly one USB serial device is present.
    private func followReplugged() {
        let old = selectedDevice
        let usb = GPSDController.serialDevices().filter { $0.contains("usb") }
        guard usb.count == 1, let new = usb.first, new != old else { return }
        append("Receiver moved to another port: \(old) → \(new)")
        refreshDevices()
        selectedDevice = new
        reader.start(path: new, baud: baudRate == 0 ? nil : baudRate)
    }

    /// The main on/off switch: starts/stops gpsd or the direct serial reader.
    func setRunning(_ on: Bool) {
        switch source {
        case .gpsd:
            setGPSD(on)
        case .direct:
            if on {
                guard !selectedDevice.isEmpty else { alertMessage = GPSDController.ControlError.noDevice.localizedDescription; return }
                reader.start(path: selectedDevice, baud: baudRate == 0 ? nil : baudRate)
                directState = .opening
            } else {
                reader.stop()
                directState = .stopped
            }
        }
    }

    func append(_ line: String) {
        let f = Date.FormatStyle().hour().minute().second()
        log.append("[\(Date().formatted(f))] \(line)")
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
    }

    func poll() {
        let port = gpsdPort
        let managed = controller.isManagedRunning
        Task.detached {
            let listening = GPSDController.isListening(port: port)
            await MainActor.run {
                if !self.gpsdBusy { self.gpsdRunning = managed || listening }
            }
        }
    }

    func refreshDevices() {
        serialDevices = GPSDController.serialDevices()
        // Keep a custom path (e.g. a udev-style symlink) as long as it exists.
        if !selectedDevice.isEmpty, !serialDevices.contains(selectedDevice),
           FileManager.default.fileExists(atPath: selectedDevice) {
            serialDevices.insert(selectedDevice, at: 0)
        }
        if selectedDevice.isEmpty || !serialDevices.contains(selectedDevice) {
            selectedDevice = serialDevices.first ?? selectedDevice
        }
    }

    // MARK: - gpsd switch

    func setGPSD(_ on: Bool) {
        guard on != gpsdRunning, !gpsdBusy else { return }
        gpsdBusy = true
        gpsdRunning = on
        do {
            if on {
                try controller.start(device: selectedDevice, port: gpsdPort,
                                     gpsdPath: gpsdPathOverride, listenOnLAN: gpsdLAN)
                append("gpsd started for \(selectedDevice)")
            } else {
                try controller.stop()
                append("gpsd stopped")
            }
        } catch {
            gpsdRunning = !on
            alertMessage = error.localizedDescription
            append("Error: \(error.localizedDescription)")
        }
        // Give gpsd a moment to open its socket before re-polling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.gpsdBusy = false
            self.client.reconnect()
            self.poll()
        }
    }

    func shutdown() {
        reader.stop()
        if controller.isManagedRunning { try? controller.stop() }
        if gpxRecording { stopGPX() }
        bridge.stopAll()
    }

    // MARK: - Bridge

    func applyNMEA() {
        bridge.nmeaServer.stop()
        guard nmeaEnabled else { return }
        do {
            try bridge.nmeaServer.start(port: UInt16(clamping: nmeaPort), lanAccess: nmeaLAN)
            append("NMEA TCP server on port \(nmeaPort)\(nmeaLAN ? " (LAN)" : " (local only)")")
        } catch {
            alertMessage = "NMEA server: \(error.localizedDescription)"
            nmeaEnabled = false
        }
    }

    func applyPTY() {
        bridge.pty.stop()
        ptyDevice = nil
        guard ptyEnabled else { return }
        do {
            try bridge.pty.start(linkPath: ptyPath)
            ptyDevice = bridge.pty.deviceName
            append("Virtual serial port: \(ptyPath) → \(ptyDevice ?? "?")")
        } catch {
            alertMessage = error.localizedDescription
            ptyEnabled = false
        }
    }

    func applyHTTP() {
        bridge.http.stop()
        guard httpEnabled else { return }
        do {
            try bridge.http.start(port: UInt16(clamping: httpPort))
            append("HTTP API: http://127.0.0.1:\(httpPort)/position")
        } catch {
            alertMessage = "HTTP: \(error.localizedDescription)"
            httpEnabled = false
        }
    }

    func applyJSON() {
        bridge.jsonFileURL = jsonEnabled ? GPSBridge.defaultJSONURL : nil
    }

    func startGPX() {
        do {
            gpxURL = try bridge.gpx.start(directory: GPSBridge.defaultGPXDirectory)
            gpxRecording = true
            gpxPoints = 0
            append("GPX recording: \(gpxURL?.path ?? "")")
        } catch {
            alertMessage = "GPX: \(error.localizedDescription)"
        }
    }

    func stopGPX() {
        if let url = bridge.gpx.stop() { append("GPX saved: \(url.path) (\(gpxPoints) points)") }
        gpxRecording = false
    }

    // MARK: - macOS helpers

    func copyCoordinates() {
        guard let lat = tpv.lat, let lon = tpv.lon else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(format: "%.7f, %.7f", lat, lon), forType: .string)
    }

    func openInMaps() {
        guard let lat = tpv.lat, let lon = tpv.lon,
              let url = MapsLink.url(latitude: lat, longitude: lon) else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
