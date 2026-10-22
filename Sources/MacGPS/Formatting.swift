import Foundation
import SwiftUI
import GPSCore

enum Fmt {
    static let dash = "—"

    static func decimal(_ v: Double?, pos: String, neg: String) -> String {
        guard let v else { return dash }
        return String(format: "%.7f° %@", abs(v), v >= 0 ? pos : neg)
    }

    static func dms(_ v: Double?, pos: String, neg: String) -> String {
        guard let v else { return dash }
        let a = abs(v)
        let d = Int(a)
        let mFull = (a - Double(d)) * 60
        let m = Int(mFull)
        let s = (mFull - Double(m)) * 60
        return String(format: "%d° %02d′ %06.3f″ %@", d, m, s, v >= 0 ? pos : neg)
    }

    static func num(_ v: Double?, _ unit: String, digits: Int = 1) -> String {
        guard let v else { return dash }
        return String(format: "%.\(digits)f %@", v, unit)
    }

    static func time(_ tpv: TPV) -> String {
        guard let d = tpv.date else { return tpv.time ?? dash }
        let f = Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!)
            .year().month().day().time(includingFractionalSeconds: false)
        return d.formatted(f).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: " UTC")
    }
}

/// Signal colours like xgps.
func snrColor(_ ss: Double?) -> Color {
    guard let ss, ss > 0 else { return .gray }
    switch ss {
    case ..<10: return .gray
    case ..<30: return .red
    case ..<35: return .orange
    case ..<40: return .yellow
    default: return .green
    }
}
