import Foundation

/// Parses NMEA-0183 sentences (RMC, GGA, GSA, GSV, GST, VTG, ZDA) from any talker
/// (GP, GN, GL, GA, GB/BD, GQ, GI) into gpsd-style TPV and SKY reports.
public struct NMEAParser {
    public struct Changes: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let tpv = Changes(rawValue: 1)
        public static let sky = Changes(rawValue: 2)
    }

    struct SatKey: Hashable { var gnss: Int; var prn: Int }

    public var device: String?

    private var timeOfDay: String?
    private var date: (y: Int, m: Int, d: Int)?
    private var lat: Double?
    private var lon: Double?
    private var altMSL: Double?
    private var geoidSep: Double?
    private var speed: Double?
    private var track: Double?
    private var rmcValid: Bool?
    private var ggaQuality: Int?
    private var ggaSats: Int?
    private var ggaHDOP: Double?
    private var gsaMode: Int?
    private var pdop: Double?
    private var hdop: Double?
    private var vdop: Double?
    private var errLat: Double?
    private var errLon: Double?
    private var errAlt: Double?
    private var used: [String: (keys: Set<SatKey>, at: Date)] = [:]
    private var gsvPending: [String: [Satellite]] = [:]
    private var gsvCommitted: [String: (sats: [Satellite], at: Date)] = [:]

    public init(device: String? = nil) { self.device = device }

    // MARK: - Checksum

    /// Returns the comma-separated fields of a sentence if its checksum is valid.
    public static func validatedFields(_ line: String) -> [String]? {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = s.first, first == "$" || first == "!",
              let star = s.lastIndex(of: "*") else { return nil }
        let body = s[s.index(after: s.startIndex)..<star]
        let given = s[s.index(after: star)...].prefix(2)
        guard given.count == 2, NMEA.checksum(String(body)) == given.uppercased() else { return nil }
        return body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - Feeding

    @discardableResult
    public mutating func feed(_ line: String) -> Changes {
        guard let f = Self.validatedFields(line), let head = f.first, head.count >= 5,
              !head.hasPrefix("P") else { return [] }
        let talker = String(head.prefix(2))
        switch String(head.suffix(3)) {
        case "RMC": return parseRMC(f)
        case "GGA": return parseGGA(f)
        case "GSA": return parseGSA(f, talker: talker)
        case "GSV": return parseGSV(f, talker: talker)
        case "GST": return parseGST(f)
        case "VTG": return parseVTG(f)
        case "ZDA": return parseZDA(f)
        default: return []
        }
    }

    private static func field(_ f: [String], _ i: Int) -> String? {
        i < f.count && !f[i].isEmpty ? f[i] : nil
    }
    private static func dbl(_ f: [String], _ i: Int) -> Double? { field(f, i).flatMap(Double.init) }
    private static func int(_ f: [String], _ i: Int) -> Int? { field(f, i).flatMap { Int($0) } }

    private static func coordinate(_ value: String?, _ hemi: String?) -> Double? {
        guard let value, let v = Double(value), let hemi else { return nil }
        let deg = (v / 100).rounded(.towardZero)
        let result = deg + (v - deg * 100) / 60
        return (hemi == "S" || hemi == "W") ? -result : result
    }

    private mutating func parseRMC(_ f: [String]) -> Changes {
        if let t = Self.field(f, 1) { timeOfDay = t }
        rmcValid = Self.field(f, 2) == "A" && Self.field(f, 12) != "N"
        if let la = Self.coordinate(Self.field(f, 3), Self.field(f, 4)),
           let lo = Self.coordinate(Self.field(f, 5), Self.field(f, 6)) { lat = la; lon = lo }
        speed = Self.dbl(f, 7).map { $0 / 1.943844492 } ?? speed
        track = Self.dbl(f, 8) ?? track
        if let d = Self.field(f, 9), d.count == 6, let dd = Int(d.prefix(2)),
           let mm = Int(d.dropFirst(2).prefix(2)), let yy = Int(d.suffix(2)) {
            date = (yy < 80 ? 2000 + yy : 1900 + yy, mm, dd)
        }
        return .tpv
    }

    private mutating func parseGGA(_ f: [String]) -> Changes {
        if let t = Self.field(f, 1) { timeOfDay = t }
        if let la = Self.coordinate(Self.field(f, 2), Self.field(f, 3)),
           let lo = Self.coordinate(Self.field(f, 4), Self.field(f, 5)) { lat = la; lon = lo }
        ggaQuality = Self.int(f, 6)
        ggaSats = Self.int(f, 7)
        ggaHDOP = Self.dbl(f, 8)
        altMSL = Self.dbl(f, 9)
        geoidSep = Self.dbl(f, 11)
        return [.tpv, .sky]
    }

    private mutating func parseGSA(_ f: [String], talker: String) -> Changes {
        gsaMode = Self.int(f, 2)
        pdop = Self.dbl(f, 15) ?? pdop
        hdop = Self.dbl(f, 16) ?? hdop
        vdop = Self.dbl(f, 17) ?? vdop
        let systemID = Self.int(f, 18)
        let prns = (3...14).compactMap { Self.int(f, $0) }
        let keys = Set(prns.map { SatKey(gnss: Self.gnss(talker: talker, systemID: systemID, prn: $0), prn: $0) })
        let group: String
        if let systemID { group = "sys\(systemID)" }
        else if talker != "GN" { group = talker }
        else if let first = keys.first { group = "gn\(first.gnss)" }
        else { return [.tpv, .sky] }
        used[group] = (keys, Date())
        return [.tpv, .sky]
    }

    private mutating func parseGSV(_ f: [String], talker: String) -> Changes {
        guard let total = Self.int(f, 1), let num = Self.int(f, 2) else { return [] }
        let rest = f.count - 4
        let signal = rest % 4 == 1 ? (f.last ?? "") : ""
        let key = talker + signal
        if num == 1 { gsvPending[key] = [] }
        var list = gsvPending[key] ?? []
        var i = 4
        while i + 3 < f.count {
            if let prn = Self.int(f, i) {
                let gnss = Self.gnss(talker: talker, systemID: nil, prn: prn)
                list.append(Satellite(prn: prn, el: Self.dbl(f, i + 1), az: Self.dbl(f, i + 2),
                                      ss: Self.dbl(f, i + 3), used: false, gnssid: gnss, svid: prn))
            }
            i += 4
        }
        gsvPending[key] = list
        if num >= total {
            gsvCommitted[key] = (list, Date())
            gsvPending[key] = nil
            return .sky
        }
        return []
    }

    private mutating func parseGST(_ f: [String]) -> Changes {
        errLat = Self.dbl(f, 6)
        errLon = Self.dbl(f, 7)
        errAlt = Self.dbl(f, 8)
        return .tpv
    }

    private mutating func parseVTG(_ f: [String]) -> Changes {
        if let t = Self.dbl(f, 1) { track = t }
        if let kmh = Self.dbl(f, 7) { speed = kmh / 3.6 }
        return .tpv
    }

    private mutating func parseZDA(_ f: [String]) -> Changes {
        if let t = Self.field(f, 1) { timeOfDay = t }
        if let d = Self.int(f, 2), let m = Self.int(f, 3), let y = Self.int(f, 4) { date = (y, m, d) }
        return []
    }

    /// gpsd gnssid: 0 GPS, 1 SBAS, 2 Galileo, 3 BeiDou, 5 QZSS, 6 GLONASS, 7 NavIC.
    static func gnss(talker: String, systemID: Int?, prn: Int) -> Int {
        if let systemID {
            switch systemID {
            case 1: return (33...64).contains(prn) ? 1 : 0
            case 2: return 6
            case 3: return 2
            case 4: return 3
            case 5: return 5
            case 6: return 7
            default: break
            }
        }
        switch talker {
        case "GL": return 6
        case "GA": return 2
        case "GB", "BD": return 3
        case "GQ", "QZ": return 5
        case "GI": return 7
        case "GP" where !(33...64).contains(prn) && !(193...202).contains(prn): return 0
        default:
            switch prn {
            case 1...32: return 0
            case 33...64, 120...158: return 1
            case 65...96: return 6
            case 193...202: return 5
            case 201...263, 401...437: return 3
            case 301...336: return 2
            default: return 0
            }
        }
    }

    // MARK: - Snapshots

    public var tpv: TPV {
        var t = TPV()
        t.device = device
        t.time = isoTime()
        let quality = ggaQuality ?? 0
        let mode: Int
        if rmcValid == false && quality == 0 { mode = 1 }
        else if let m = gsaMode, m >= 2 { mode = m }
        else if quality > 0 { mode = altMSL != nil ? 3 : 2 }
        else if rmcValid == true { mode = 2 }
        else { mode = (timeOfDay != nil) ? 1 : 0 }
        t.mode = mode
        t.status = [2: 2, 4: 3, 5: 4, 6: 5][quality] ?? 1
        t.lat = lat
        t.lon = lon
        if mode >= 3 {
            t.altMSL = altMSL
            t.alt = altMSL
            t.geoidSep = geoidSep
            if let a = altMSL, let s = geoidSep { t.altHAE = a + s }
        }
        t.speed = speed
        t.track = track
        Self.applyAccuracy(to: &t, quality: quality, hdop: hdop ?? ggaHDOP, vdop: vdop,
                           sigmaLat: errLat, sigmaLon: errLon, sigmaAlt: errAlt)
        return t
    }

    /// Typical 1σ user equivalent range error (m) per fix quality.
    static func uere(quality: Int) -> Double {
        switch quality {
        case 4: return 0.02  // RTK fixed
        case 5: return 0.3   // RTK float
        case 2: return 1.5   // DGPS / SBAS
        default: return 4.0  // autonomous
        }
    }

    /// Fills epx/epy/epv/eph as ~95 % (2σ) values, like gpsd.
    /// Uses the receiver's own error estimate (GST) when available, otherwise DOP × UERE.
    static func applyAccuracy(to t: inout TPV, quality: Int, hdop: Double?, vdop: Double?,
                              sigmaLat: Double?, sigmaLon: Double?, sigmaAlt: Double?) {
        guard (t.mode ?? 0) >= 2 else { return }
        if let sx = sigmaLon, let sy = sigmaLat {
            t.epx = 2 * sx
            t.epy = 2 * sy
            t.eph = 2 * (sx * sx + sy * sy).squareRoot()
            if let sz = sigmaAlt { t.epv = 2 * sz }
            t.errorEstimated = false
            return
        }
        let u = uere(quality: quality)
        // 99.99 is the receivers' "no value" marker
        if let h = hdop, h > 0, h < 99 { t.eph = 2 * h * u }
        if let v = vdop, v > 0, v < 99, (t.mode ?? 0) >= 3 { t.epv = 2 * v * u }
        if t.eph != nil || t.epv != nil { t.errorEstimated = true }
    }

    public var sky: SKY {
        let now = Date()
        let usedKeys = used.values.filter { now.timeIntervalSince($0.at) < 5 }
            .reduce(into: Set<SatKey>()) { $0.formUnion($1.keys) }
        var merged: [SatKey: Satellite] = [:]
        var order: [SatKey] = []
        for (_, entry) in gsvCommitted.sorted(by: { $0.key < $1.key }) where now.timeIntervalSince(entry.at) < 10 {
            for sat in entry.sats {
                let key = SatKey(gnss: sat.gnssid ?? 0, prn: sat.prn)
                if var existing = merged[key] {
                    existing.ss = [existing.ss, sat.ss].compactMap { $0 }.max()
                    existing.el = existing.el ?? sat.el
                    existing.az = existing.az ?? sat.az
                    merged[key] = existing
                } else {
                    merged[key] = sat
                    order.append(key)
                }
            }
        }
        var sats = order.compactMap { merged[$0] }
        for i in sats.indices {
            sats[i].used = usedKeys.contains(SatKey(gnss: sats[i].gnssid ?? 0, prn: sats[i].prn))
        }
        var s = SKY()
        s.device = device
        s.time = isoTime()
        s.satellites = sats
        s.nSat = sats.count
        s.uSat = usedKeys.isEmpty ? ggaSats : sats.filter(\.isUsed).count
        s.hdop = hdop ?? ggaHDOP
        s.pdop = pdop
        s.vdop = vdop
        return s
    }

    private func isoTime() -> String? {
        guard let t = timeOfDay, t.count >= 6 else { return nil }
        let hh = t.prefix(2), mm = t.dropFirst(2).prefix(2), ss = t.dropFirst(4).prefix(2)
        let frac = t.split(separator: ".").dropFirst().first.map { "." + $0.prefix(3) } ?? ""
        let d: (y: Int, m: Int, d: Int)
        if let date { d = date } else {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let c = cal.dateComponents([.year, .month, .day], from: Date())
            d = (c.year ?? 2000, c.month ?? 1, c.day ?? 1)
        }
        return String(format: "%04d-%02d-%02dT", d.y, d.m, d.d) + "\(hh):\(mm):\(ss)\(frac)Z"
    }
}
