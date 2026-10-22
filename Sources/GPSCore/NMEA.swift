import Foundation

/// Generates NMEA-0183 sentences (GGA, RMC, VTG, GSA, GSV) from gpsd reports.
/// Works for any receiver gpsd supports, including binary-only protocols (u-blox, SiRF, …).
public enum NMEA {
    public static func checksum(_ body: String) -> String {
        var c: UInt8 = 0
        for b in body.utf8 { c ^= b }
        return String(format: "%02X", c)
    }

    public static func sentence(_ body: String) -> String {
        "$\(body)*\(checksum(body))\r\n"
    }

    static func coordinate(_ value: Double, degreeDigits: Int, pos: String, neg: String) -> (String, String) {
        let a = abs(value)
        var d = Int(a)
        var m = (a - Double(d)) * 60
        if m >= 59.999995 { d += 1; m = 0 }
        return (String(format: "%0\(degreeDigits)d%08.5f", d, m), value >= 0 ? pos : neg)
    }

    static func utcParts(_ date: Date) -> (time: String, date: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let centis = (c.nanosecond ?? 0) / 10_000_000
        let t = String(format: "%02d%02d%02d.%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, centis)
        let d = String(format: "%02d%02d%02d", c.day ?? 0, c.month ?? 0, (c.year ?? 0) % 100)
        return (t, d)
    }

    private static func f(_ v: Double?, _ format: String) -> String {
        v.map { String(format: format, $0) } ?? ""
    }

    public static func sentences(tpv: TPV, sky: SKY?) -> [String] {
        // No GPS time yet → leave the fields empty instead of inventing one.
        let (time, day) = tpv.date.map(utcParts) ?? ("", "")
        let fix = tpv.hasFix
        var lat = ("", ""), lon = ("", "")
        if fix, let la = tpv.lat, let lo = tpv.lon {
            lat = coordinate(la, degreeDigits: 2, pos: "N", neg: "S")
            lon = coordinate(lo, degreeDigits: 3, pos: "E", neg: "W")
        }
        let knots = tpv.speed.map { $0 * 1.943844492 }
        let kmh = tpv.speed.map { $0 * 3.6 }

        // GGA
        let quality: Int = !fix ? 0 : (tpv.status == 2 ? 2 : tpv.status == 3 ? 4 : tpv.status == 4 ? 5 : 1)
        let used = sky?.usedCount ?? 0
        let sep: Double? = tpv.geoidSep ?? {
            if let h = tpv.altHAE, let m = tpv.altMSL { return h - m }
            return nil
        }()
        let alt = (fix && (tpv.mode ?? 0) >= 3) ? tpv.altitudeMSL : nil
        var out: [String] = []
        out.append(sentence("GPGGA,\(time),\(lat.0),\(lat.1),\(lon.0),\(lon.1),\(quality),\(String(format: "%02d", used)),\(f(sky?.hdop, "%.2f")),\(f(alt, "%.1f")),M,\(f(sep, "%.1f")),M,,"))

        // RMC
        let modeIndicator = !fix ? "N" : (tpv.status == 2 ? "D" : "A")
        out.append(sentence("GPRMC,\(time),\(fix ? "A" : "V"),\(lat.0),\(lat.1),\(lon.0),\(lon.1),\(f(fix ? knots : nil, "%.2f")),\(f(fix ? tpv.track : nil, "%.1f")),\(day),,,\(modeIndicator)"))

        // VTG
        out.append(sentence("GPVTG,\(f(fix ? tpv.track : nil, "%.1f")),T,,M,\(f(fix ? knots : nil, "%.2f")),N,\(f(fix ? kmh : nil, "%.2f")),K,\(modeIndicator)"))

        // GSA
        let sats = sky?.satellites ?? []
        var prns = sats.filter(\.isUsed).prefix(12).map { String(format: "%02d", $0.prn) }
        while prns.count < 12 { prns.append("") }
        let fixType = max(1, min(3, tpv.mode ?? 1))
        out.append(sentence("GPGSA,A,\(fixType),\(prns.joined(separator: ",")),\(f(sky?.pdop, "%.2f")),\(f(sky?.hdop, "%.2f")),\(f(sky?.vdop, "%.2f"))"))

        // GSV
        let visible = sats.filter { $0.el != nil && $0.az != nil }
        if !visible.isEmpty {
            let groups = stride(from: 0, to: visible.count, by: 4).map { Array(visible[$0..<min($0 + 4, visible.count)]) }
            for (i, group) in groups.enumerated() {
                let fields = group.map { s in
                    String(format: "%02d,%02d,", s.prn, Int((s.el ?? 0).rounded())) + "\(String(format: "%03d", Int((s.az ?? 0).rounded()) % 360)),\(s.ss.map { String(Int($0.rounded())) } ?? "")"
                }.joined(separator: ",")
                out.append(sentence("GPGSV,\(groups.count),\(i + 1),\(String(format: "%02d", visible.count)),\(fields)"))
            }
        }
        return out
    }
}
