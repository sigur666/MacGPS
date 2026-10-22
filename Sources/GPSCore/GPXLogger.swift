import Foundation

/// Records the track as a GPX 1.1 file.
public final class GPXLogger {
    private let lock = NSLock()
    private var handle: FileHandle?
    public private(set) var url: URL?
    public private(set) var pointCount = 0
    private var lastTime: String?

    public init() {}
    public var isRecording: Bool { lock.withLock { handle != nil } }

    @discardableResult
    public func start(directory: URL) throws -> URL {
        stop()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileURL = directory.appendingPathComponent("track_\(f.string(from: Date())).gpx")
        let header = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="MacGPS" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>MacGPS \(f.string(from: Date()))</name><trkseg>

        """
        try header.write(to: fileURL, atomically: true, encoding: .utf8)
        let h = try FileHandle(forWritingTo: fileURL)
        h.seekToEndOfFile()
        lock.withLock { handle = h; url = fileURL; pointCount = 0; lastTime = nil }
        return fileURL
    }

    public func add(_ tpv: TPV) {
        guard tpv.hasFix, let lat = tpv.lat, let lon = tpv.lon else { return }
        lock.withLock {
            guard let handle, tpv.time != lastTime else { return }
            lastTime = tpv.time
            var pt = String(format: "    <trkpt lat=\"%.8f\" lon=\"%.8f\">", lat, lon)
            if let ele = tpv.altitudeMSL { pt += String(format: "<ele>%.2f</ele>", ele) }
            if let t = tpv.time { pt += "<time>\(t)</time>" }
            pt += "</trkpt>\n"
            handle.write(Data(pt.utf8))
            pointCount += 1
        }
    }

    @discardableResult
    public func stop() -> URL? {
        lock.withLock {
            guard let h = handle else { return nil }
            h.write(Data("  </trkseg></trk>\n</gpx>\n".utf8))
            try? h.close()
            handle = nil
            return url
        }
    }
}
