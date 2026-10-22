import Foundation

/// Fans gpsd data out into formats other macOS software can consume:
/// NMEA over TCP, a virtual serial port, a local HTTP/JSON API, a JSON file and GPX tracks.
public final class GPSBridge {
    public let nmeaServer = NMEATCPServer()
    public let pty = PTYBridge()
    public let http = HTTPServer()
    public let gpx = GPXLogger()

    /// If set, the latest position is written atomically to this file on every fix.
    public var jsonFileURL: URL? {
        get { lock.withLock { _jsonFileURL } }
        set { lock.withLock { _jsonFileURL = newValue } }
    }

    private let lock = NSLock()
    private var _jsonFileURL: URL?
    private var lastTPV = TPV()
    private var lastSKY: SKY?
    private var lastNMEA: [String] = []
    private let io = DispatchQueue(label: "macgps.bridge.io")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public init() {
        http.route = { [weak self] path in
            self?.respond(to: path) ?? HTTPServer.Response(status: 503, body: Data())
        }
    }

    public static var defaultJSONURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacGPS/position.json")
    }

    public static var defaultGPXDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacGPS Tracks")
    }

    public func ingest(sky: SKY) {
        lock.withLock { lastSKY = sky }
    }

    public func ingest(tpv: TPV) {
        let (sky, jsonURL): (SKY?, URL?) = lock.withLock {
            lastTPV = tpv
            return (lastSKY, _jsonFileURL)
        }

        let sentences = NMEA.sentences(tpv: tpv, sky: sky)
        lock.withLock { lastNMEA = sentences }
        let text = sentences.joined()
        nmeaServer.send(text)
        pty.send(text)
        gpx.add(tpv)

        if let jsonURL {
            let position = Position(tpv: tpv, sky: sky)
            io.async { [encoder] in
                guard let data = try? encoder.encode(position) else { return }
                try? FileManager.default.createDirectory(at: jsonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: jsonURL, options: .atomic)
            }
        }
    }

    /// The NMEA sentences generated for the latest fix.
    public var nmeaSentences: [String] { lock.withLock { lastNMEA } }

    public var position: Position { lock.withLock { Position(tpv: lastTPV, sky: lastSKY) } }

    private func json<T: Encodable>(_ value: T) -> HTTPServer.Response {
        HTTPServer.Response(body: (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    private func respond(to path: String) -> HTTPServer.Response {
        let (tpv, sky, nmea) = lock.withLock { (lastTPV, lastSKY, lastNMEA) }
        switch path {
        case "/", "/position":
            return json(Position(tpv: tpv, sky: sky))
        case "/tpv":
            return json(tpv)
        case "/sky":
            return json(sky ?? SKY())
        case "/nmea":
            return HTTPServer.Response(contentType: "text/plain", body: Data(nmea.joined().utf8))
        case "/geojson":
            var feature: [String: Any] = ["type": "Feature"]
            if tpv.hasFix, let lat = tpv.lat, let lon = tpv.lon {
                var coords = [lon, lat]
                if let alt = tpv.altitudeMSL { coords.append(alt) }
                feature["geometry"] = ["type": "Point", "coordinates": coords]
            } else {
                feature["geometry"] = NSNull()
            }
            let p = Position(tpv: tpv, sky: sky)
            let props = (try? JSONSerialization.jsonObject(with: encoder.encode(p))) ?? [:]
            feature["properties"] = props
            let data = (try? JSONSerialization.data(withJSONObject: feature, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return HTTPServer.Response(contentType: "application/geo+json", body: data)
        default:
            return HTTPServer.Response(status: 404, contentType: "text/plain",
                                       body: Data("Endpoints: /position /tpv /sky /nmea /geojson\n".utf8))
        }
    }

    public func stopAll() {
        nmeaServer.stop()
        pty.stop()
        http.stop()
        gpx.stop()
        jsonFileURL = nil
    }
}
