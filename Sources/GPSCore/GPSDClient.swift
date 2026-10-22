import Foundation
import Network

/// Minimal gpsd JSON protocol client (port 2947) with automatic reconnect.
public final class GPSDClient {
    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case waiting(String)

        public var description: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .waiting(let reason): return "Waiting for gpsd (\(reason))"
            }
        }
    }

    // All callbacks are delivered on `callbackQueue`.
    public var onState: ((State) -> Void)?
    public var onTPV: ((TPV) -> Void)?
    public var onSKY: ((SKY) -> Void)?
    public var onVersion: ((GPSDVersion) -> Void)?
    public var onDevices: (([GPSDDevice]) -> Void)?
    public var onError: ((String) -> Void)?
    /// Every raw line received from gpsd.
    public var onRaw: ((String) -> Void)?

    public let host: String
    public let port: UInt16
    public var callbackQueue: DispatchQueue

    private let queue = DispatchQueue(label: "macgps.gpsd.client")
    private var connection: NWConnection?
    private var buffer = Data()
    private var running = false
    private var lastSKY = SKY()
    private let decoder = JSONDecoder()

    public init(host: String = "127.0.0.1", port: UInt16 = 2947, callbackQueue: DispatchQueue = .main) {
        self.host = host
        self.port = port
        self.callbackQueue = callbackQueue
    }

    public func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.connect()
        }
    }

    public func stop() {
        queue.async {
            self.running = false
            self.connection?.cancel()
            self.connection = nil
            self.emit { self.onState?(.disconnected) }
        }
    }

    /// Force an immediate reconnect attempt (e.g. right after gpsd was launched).
    public func reconnect() {
        queue.async {
            guard self.running else { return }
            self.connection?.cancel()
            self.connection = nil
            self.connect()
        }
    }

    // MARK: - Private

    private func emit(_ block: @escaping () -> Void) { callbackQueue.async(execute: block) }

    private func connect() {
        guard running, connection == nil else { return }
        buffer.removeAll()
        lastSKY = SKY()
        emit { self.onState?(.connecting) }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, conn === self.connection else { return }
            switch state {
            case .ready:
                self.emit { self.onState?(.connected) }
                let watch = "?WATCH={\"enable\":true,\"json\":true};\n"
                conn.send(content: watch.data(using: .utf8), completion: .contentProcessed { _ in })
                self.receive(on: conn)
            case .waiting(let err):
                self.emit { self.onState?(.waiting(err.localizedDescription)) }
                self.scheduleReconnect(conn)
            case .failed(let err):
                self.emit { self.onState?(.waiting(err.localizedDescription)) }
                self.scheduleReconnect(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func scheduleReconnect(_ conn: NWConnection) {
        guard conn === connection else { return }
        conn.cancel()
        connection = nil
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, conn === self.connection else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainLines()
            }
            if isComplete || error != nil {
                self.emit { self.onState?(.waiting(error?.localizedDescription ?? "connection closed")) }
                self.scheduleReconnect(conn)
            } else {
                self.receive(on: conn)
            }
        }
    }

    private func drainLines() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { continue }
            handle(line: line)
        }
        if buffer.count > 1_000_000 { buffer.removeAll() } // garbage protection
    }

    private func handle(line: String) {
        if let onRaw { emit { onRaw(line) } }
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let env = try? decoder.decode(Envelope.self, from: data) else { return }
        switch env.cls {
        case "TPV":
            if let tpv = try? decoder.decode(TPV.self, from: data) { emit { self.onTPV?(tpv) } }
        case "SKY":
            guard let sky = try? decoder.decode(SKY.self, from: data) else { return }
            // Newer gpsd versions send partial SKY reports (DOPs only) – merge them.
            var merged = sky
            if merged.satellites == nil { merged.satellites = lastSKY.satellites; merged.nSat = merged.nSat ?? lastSKY.nSat; merged.uSat = merged.uSat ?? lastSKY.uSat }
            if merged.hdop == nil { merged.hdop = lastSKY.hdop; merged.vdop = lastSKY.vdop; merged.pdop = lastSKY.pdop
                merged.gdop = lastSKY.gdop; merged.tdop = lastSKY.tdop; merged.xdop = lastSKY.xdop; merged.ydop = lastSKY.ydop }
            lastSKY = merged
            emit { self.onSKY?(merged) }
        case "VERSION":
            if let v = try? decoder.decode(GPSDVersion.self, from: data) { emit { self.onVersion?(v) } }
        case "DEVICES":
            if let d = try? decoder.decode(DevicesReport.self, from: data) { emit { self.onDevices?(d.devices ?? []) } }
        case "DEVICE":
            if let d = try? decoder.decode(GPSDDevice.self, from: data) { emit { self.onDevices?([d]) } }
        case "ERROR":
            if let e = try? decoder.decode(ErrorReport.self, from: data) { emit { self.onError?(e.message ?? line) } }
        default:
            break
        }
    }
}
