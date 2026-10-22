import SwiftUI
import GPSCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var tab = "monitor"

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            MonitorView()
                .tabItem { Label("Monitor", systemImage: "dot.radiowaves.left.and.right") }
                .tag("monitor")
            BridgeView()
                .tabItem { Label("macOS Bridge", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag("bridge")
            LogView()
                .tabItem { Label("Log", systemImage: "text.alignleft") }
                .tag("log")
        }
        .padding(.top, 4)
        .onAppear { AppDelegate.openMainWindow = { [openWindow] in openWindow(id: "main") } }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                StatusBadge()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Source", selection: $model.source) {
                    ForEach(SourceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .disabled(model.isRunning && model.source == .direct)
                .help("Use gpsd or read the receiver directly (without gpsd)")

                Picker("Receiver", selection: $model.selectedDevice) {
                    if model.serialDevices.isEmpty { Text("No device found").tag("") }
                    ForEach(model.serialDevices, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 200)
                .disabled(model.isRunning)
                .help("Serial GPS receiver")

                Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh device list")

                SourceSwitch()
            }
        }
        .alert("MacGPS", isPresented: Binding(get: { model.alertMessage != nil },
                                              set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

/// The on/off slider: starts/stops gpsd, or the direct reader in "Direct" mode.
struct SourceSwitch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Text(model.source == .gpsd ? "gpsd" : "GPS").font(.headline)
            Toggle("On/Off", isOn: Binding(get: { model.isRunning }, set: { model.setRunning($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.gpsdBusy)
            if model.gpsdBusy { ProgressView().controlSize(.small) }
        }
        .help(helpText)
    }

    private var helpText: String {
        if model.source == .direct { return "Start/stop reading the receiver directly (without gpsd)" }
        return model.gpsdFound ? "Start/stop gpsd" : "gpsd not installed – brew install gpsd or choose source \"Direct\""
    }
}

struct StatusBadge: View {
    @Environment(AppModel.self) private var model

    var color: Color {
        if !model.isConnected { return model.isRunning ? .orange : .red }
        return model.tpv.hasFix ? .green : .orange
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.statusText)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let detail = model.statusDetail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
    }
}

struct LogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading) {
            ScrollViewReader { proxy in
                List(Array(model.log.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .id(item.offset)
                }
                .onChange(of: model.log.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
            HStack {
                Spacer()
                Button("Clear") { model.log.removeAll() }
            }
            .padding([.horizontal, .bottom], 8)
        }
    }
}
