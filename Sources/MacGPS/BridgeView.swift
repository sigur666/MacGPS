import SwiftUI
import GPSCore

/// Settings for the tool that makes gpsd data usable on macOS.
struct BridgeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(isOn: $model.nmeaEnabled) {
                    VStack(alignment: .leading) {
                        Text("NMEA-0183 over TCP")
                        Text("For OpenCPN, QGIS, GPSBabel, MacENC, iPad/iPhone apps on Wi-Fi …")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("Port", value: $model.nmeaPort, format: .number.grouping(.never)).frame(width: 140)
                    Toggle("Share on local network", isOn: $model.nmeaLAN)
                }
                .disabled(model.nmeaEnabled)
                if model.nmeaEnabled {
                    Copyable("tcp://\(model.nmeaLAN ? (Host.current().localizedName.map { "\($0).local" } ?? "<mac>") : "127.0.0.1"):\(model.nmeaPort)",
                             note: "\(model.nmeaClients) client(s) connected")
                }
            } header: { Label("NMEA Server", systemImage: "network") }

            Section {
                Toggle(isOn: $model.ptyEnabled) {
                    VStack(alignment: .leading) {
                        Text("Virtual serial GPS port")
                        Text("Apps that expect a serial GPS receiver simply open this path.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("Path", text: $model.ptyPath).disabled(model.ptyEnabled)
                if model.ptyEnabled, let dev = model.ptyDevice {
                    Copyable(model.ptyPath, note: "→ \(dev), 9600 baud, NMEA")
                }
            } header: { Label("Serial Port", systemImage: "cable.connector") }

            Section {
                Toggle(isOn: $model.httpEnabled) {
                    VStack(alignment: .leading) {
                        Text("Local HTTP/JSON API")
                        Text("For scripts, Shortcuts, web apps, Home Assistant …")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("Port", value: $model.httpPort, format: .number.grouping(.never))
                    .frame(width: 140).disabled(model.httpEnabled)
                if model.httpEnabled {
                    ForEach(["position", "geojson", "nmea", "tpv", "sky"], id: \.self) { ep in
                        Copyable("http://127.0.0.1:\(model.httpPort)/\(ep)", note: nil)
                    }
                }
            } header: { Label("HTTP API", systemImage: "curlybraces") }

            Section {
                Toggle(isOn: $model.jsonEnabled) {
                    VStack(alignment: .leading) {
                        Text("Continuously write position to a JSON file")
                        Text("Easy for shell scripts: jq . <file>").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.jsonEnabled {
                    Copyable(GPSBridge.defaultJSONURL.path, note: nil)
                }
            } header: { Label("JSON File", systemImage: "doc.text") }

            Section {
                HStack {
                    if model.gpxRecording {
                        Button { model.stopGPX() } label: { Label("Stop Recording", systemImage: "stop.circle.fill") }
                            .tint(.red)
                        Text("\(model.gpxPoints) points").monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Button { model.startGPX() } label: { Label("Record GPX Track", systemImage: "record.circle") }
                    }
                    Spacer()
                    if let url = model.gpxURL {
                        Button("Show in Finder") { model.reveal(url) }
                    }
                }
                Text(GPSBridge.defaultGPXDirectory.path).font(.caption).foregroundStyle(.secondary)
            } header: { Label("Track Recording", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }

            Section {
                Picker("Source", selection: $model.source) {
                    Text("gpsd (recommended for u-blox/SiRF binary protocols)").tag(SourceMode.gpsd)
                    Text("Direct – NMEA from the serial port, without gpsd").tag(SourceMode.direct)
                }
                .pickerStyle(.radioGroup)
                .disabled(model.isRunning && model.source == .direct)
                Picker("Baud rate (Direct)", selection: $model.baudRate) {
                    Text("Auto-detect").tag(0)
                    ForEach(SerialNMEAReader.baudRates.sorted(), id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(model.directState.isActive)
            } header: { Label("Data Source", systemImage: "antenna.radiowaves.left.and.right") }

            Section {
                TextField("Path to gpsd (empty = automatic)", text: $model.gpsdPathOverride)
                Toggle("Make gpsd reachable on the network (-G)", isOn: $model.gpsdLAN)
                    .disabled(model.gpsdRunning)
                if !model.gpsdFound {
                    Label("gpsd not found. Install: brew install gpsd", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: { Label("gpsd", systemImage: "gearshape") }

            Section {
                Text("""
                macOS does not allow third-party apps to feed the system-wide Location Services \
                (CoreLocation) with their own position data. MacGPS therefore provides the data through \
                the standard interfaces that macOS programs use for external GPS receivers. \
                The command-line tool "gpsbridge" does the same without a user interface.
                """)
                .font(.callout).foregroundStyle(.secondary)
            } header: { Label("Note", systemImage: "info.circle") }
        }
        .formStyle(.grouped)
    }
}

struct Copyable: View {
    let text: String
    let note: String?
    init(_ text: String, note: String?) { self.text = text; self.note = note }

    var body: some View {
        HStack {
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let t = model.tpv
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusBadge()
                Spacer()
                SourceSwitch()
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow { Text("Latitude").foregroundStyle(.secondary); Text(Fmt.decimal(t.lat, pos: "N", neg: "S")) }
                GridRow { Text("Longitude").foregroundStyle(.secondary); Text(Fmt.decimal(t.lon, pos: "E", neg: "W")) }
                GridRow { Text("Altitude").foregroundStyle(.secondary); Text(Fmt.num(t.altitudeMSL, "m")) }
                GridRow { Text("Speed").foregroundStyle(.secondary); Text(Fmt.num(t.speed.map { $0 * 3.6 }, "km/h")) }
                GridRow { Text("Satellites").foregroundStyle(.secondary); Text("\(model.sky.usedCount) / \(model.sky.visibleCount)") }
            }
            .font(.system(.callout, design: .monospaced))
            Divider()
            HStack {
                Button("Copy") { model.copyCoordinates() }.disabled(!t.hasFix)
                Button("Maps") { model.openInMaps() }.disabled(!t.hasFix)
                Spacer()
                Button("Window") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 340)
    }
}
