import Foundation

/// gpsd "TPV" report (time / position / velocity).
public struct TPV: Codable, Sendable, Equatable {
    public var device: String?
    public var mode: Int?
    public var status: Int?
    public var time: String?
    public var lat: Double?
    public var lon: Double?
    public var alt: Double?
    public var altHAE: Double?
    public var altMSL: Double?
    public var geoidSep: Double?
    public var track: Double?
    public var magtrack: Double?
    public var speed: Double?
    public var climb: Double?
    public var eph: Double?
    public var epv: Double?
    public var epx: Double?
    public var epy: Double?
    public var eps: Double?
    public var ept: Double?
    /// Not part of gpsd: true if eph/epv were estimated from DOP instead of reported by the receiver.
    public var errorEstimated: Bool?

    public init() {}

    public var date: Date? { time.flatMap(GPSTime.parse) }
    public var altitudeMSL: Double? { altMSL ?? alt }
    public var hasFix: Bool { (mode ?? 0) >= 2 && lat != nil && lon != nil }

    public var modeDescription: String {
        switch mode ?? 0 {
        case 1: return "No fix"
        case 2: return "2D fix"
        case 3:
            switch status ?? 1 {
            case 2: return "3D fix (DGPS)"
            case 3: return "3D fix (RTK fixed)"
            case 4: return "3D fix (RTK float)"
            case 5: return "Dead reckoning"
            default: return "3D fix"
            }
        default: return "Unknown"
        }
    }
}

public struct Satellite: Codable, Sendable, Hashable, Identifiable {
    public var prn: Int
    public var el: Double?
    public var az: Double?
    public var ss: Double?
    public var used: Bool?
    public var gnssid: Int?
    public var svid: Int?
    public var health: Int?

    enum CodingKeys: String, CodingKey {
        case prn = "PRN", el, az, ss, used, gnssid, svid, health
    }

    public init(prn: Int, el: Double?, az: Double?, ss: Double?, used: Bool?, gnssid: Int? = nil, svid: Int? = nil) {
        self.prn = prn; self.el = el; self.az = az; self.ss = ss; self.used = used
        self.gnssid = gnssid; self.svid = svid
    }

    public var id: String { "\(gnssid ?? -1)-\(svid ?? prn)-\(prn)" }
    public var isUsed: Bool { used ?? false }

    /// Short constellation label, as shown by xgps.
    public var gnssName: String {
        switch gnssid {
        case 0: return "GP"
        case 1: return "SB"
        case 2: return "GA"
        case 3: return "BD"
        case 4: return "IM"
        case 5: return "QZ"
        case 6: return "GL"
        case 7: return "IR"
        default:
            // Fallback on NMEA-style PRN ranges
            switch prn {
            case 1...32: return "GP"
            case 33...64, 120...158: return "SB"
            case 65...96: return "GL"
            case 193...202: return "QZ"
            case 201...237, 401...437: return "BD"
            case 301...336: return "GA"
            default: return "??"
            }
        }
    }
}

/// gpsd "SKY" report (satellites and DOPs).
public struct SKY: Codable, Sendable, Equatable {
    public var device: String?
    public var time: String?
    public var xdop: Double?
    public var ydop: Double?
    public var vdop: Double?
    public var tdop: Double?
    public var hdop: Double?
    public var gdop: Double?
    public var pdop: Double?
    public var nSat: Int?
    public var uSat: Int?
    public var satellites: [Satellite]?

    public init() {}

    public var visibleCount: Int { nSat ?? satellites?.count ?? 0 }
    public var usedCount: Int { uSat ?? satellites?.filter(\.isUsed).count ?? 0 }
}

public struct GPSDVersion: Codable, Sendable {
    public var release: String?
    public var rev: String?
    public var proto_major: Int?
    public var proto_minor: Int?
}

public struct GPSDDevice: Codable, Sendable, Hashable {
    public var path: String?
    public var driver: String?
    public var subtype: String?
    public var activated: String?
    public var bps: Int?
}

struct DevicesReport: Codable { var devices: [GPSDDevice]? }
struct ErrorReport: Codable { var message: String? }
struct Envelope: Decodable {
    var cls: String
    enum CodingKeys: String, CodingKey { case cls = "class" }
}

public enum GPSTime {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s)
    }
}

/// Simplified, stable position record used by the bridges (HTTP, JSON file).
public struct Position: Codable, Sendable {
    public var time: String?
    public var mode: Int
    public var fix: String
    public var latitude: Double?
    public var longitude: Double?
    public var altitudeMSL: Double?
    public var altitudeHAE: Double?
    public var speed: Double?
    public var speedKmh: Double?
    public var course: Double?
    public var climb: Double?
    public var horizontalAccuracy: Double?
    public var verticalAccuracy: Double?
    /// "receiver" or "estimated (DOP × UERE)"
    public var accuracySource: String?
    public var hdop: Double?
    public var pdop: Double?
    public var satellitesUsed: Int?
    public var satellitesVisible: Int?
    public var device: String?

    public init(tpv: TPV, sky: SKY?) {
        time = tpv.time
        mode = tpv.mode ?? 0
        fix = tpv.modeDescription
        latitude = tpv.lat
        longitude = tpv.lon
        altitudeMSL = tpv.altitudeMSL
        altitudeHAE = tpv.altHAE
        speed = tpv.speed
        speedKmh = tpv.speed.map { $0 * 3.6 }
        course = tpv.track
        climb = tpv.climb
        horizontalAccuracy = tpv.eph ?? tpv.epx.flatMap { x in tpv.epy.map { y in max(x, y) } }
        verticalAccuracy = tpv.epv
        if horizontalAccuracy != nil || verticalAccuracy != nil {
            accuracySource = tpv.errorEstimated == true ? "estimated (DOP × UERE)" : "receiver"
        }
        hdop = sky?.hdop
        pdop = sky?.pdop
        satellitesUsed = sky?.usedCount
        satellitesVisible = sky?.visibleCount
        device = tpv.device
    }
}
