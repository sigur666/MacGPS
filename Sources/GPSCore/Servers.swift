import Foundation
import Network

private func makeListener(port: UInt16, lanAccess: Bool) throws -> NWListener {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    guard let p = NWEndpoint.Port(rawValue: port) else { throw POSIXError(.EINVAL) }
    if lanAccess { return try NWListener(using: params, on: p) }
    params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: p)
    return try NWListener(using: params)
}

/// Streams NMEA-0183 to any number of TCP clients (default port 10110, the IANA NMEA port).
/// Usable by OpenCPN, QGIS, GPSBabel, Navionics-style apps, iPad apps on the LAN, etc.
public final class NMEATCPServer {
    public var onClientsChanged: ((Int) -> Void)?
    public var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "macgps.nmea.tcp")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]

    public init() {}
    public var isRunning: Bool { queue.sync { listener != nil } }

    public func start(port: UInt16 = 10110, lanAccess: Bool = false) throws {
        let l = try makeListener(port: port, lanAccess: lanAccess)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state { self?.onError?("NMEA-TCP: \(e.localizedDescription)") }
        }
        queue.sync { listener = l }
        l.start(queue: queue)
    }

    public func stop() {
        queue.sync {
            listener?.cancel(); listener = nil
            clients.values.forEach { $0.cancel() }
            clients.removeAll()
        }
        onClientsChanged?(0)
    }

    public func send(_ text: String) {
        let data = Data(text.utf8)
        queue.async { [weak self] in
            guard let self else { return }
            for c in self.clients.values {
                c.send(content: data, completion: .contentProcessed { [weak self] err in
                    if err != nil { self?.remove(c) }
                })
            }
        }
    }

    private func accept(_ c: NWConnection) {
        clients[ObjectIdentifier(c)] = c
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.remove(c)
            default: break
            }
        }
        c.start(queue: queue)
        drain(c)
        onClientsChanged?(clients.count)
    }

    private func drain(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, err in
            if done || err != nil { self?.remove(c) } else { self?.drain(c) }
        }
    }

    private func remove(_ c: NWConnection) {
        guard clients.removeValue(forKey: ObjectIdentifier(c)) != nil else { return }
        c.cancel()
        onClientsChanged?(clients.count)
    }
}

/// Tiny HTTP/1.0 server that answers GET requests with a route closure.
public final class HTTPServer {
    public struct Response {
        public var status: Int
        public var contentType: String
        public var body: Data
        public init(status: Int = 200, contentType: String = "application/json", body: Data) {
            self.status = status; self.contentType = contentType; self.body = body
        }
    }

    public var route: ((String) -> Response)?
    public var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "macgps.http")
    private var listener: NWListener?

    public init() {}

    public func start(port: UInt16 = 8947, lanAccess: Bool = false) throws {
        let l = try makeListener(port: port, lanAccess: lanAccess)
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state { self?.onError?("HTTP: \(e.localizedDescription)") }
        }
        listener = l
        l.start(queue: queue)
    }

    public func stop() { listener?.cancel(); listener = nil }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { c.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let parts = request.split(separator: " ", maxSplits: 2)
            let response: Response
            if parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" {
                let path = String(parts[1].split(separator: "?").first ?? "/")
                response = self.route?(path) ?? Response(status: 404, contentType: "text/plain", body: Data("not found\n".utf8))
            } else {
                response = Response(status: 405, contentType: "text/plain", body: Data("method not allowed\n".utf8))
            }
            let reason = [200: "OK", 404: "Not Found", 405: "Method Not Allowed", 503: "Service Unavailable"][response.status] ?? "OK"
            var head = "HTTP/1.0 \(response.status) \(reason)\r\n"
            head += "Content-Type: \(response.contentType)\r\n"
            head += "Content-Length: \(response.body.count)\r\n"
            head += "Access-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            var payload = Data(head.utf8)
            if parts.first != "HEAD" { payload.append(response.body) }
            c.send(content: payload, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}
