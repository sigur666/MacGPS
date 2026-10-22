import SwiftUI
import GPSCore

/// xgps-style main view: sky plot, signal bars, fix data and satellite list.
struct MonitorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            VStack(spacing: 10) {
                SkyView(satellites: model.satellites)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(minWidth: 300)
                SignalBars(satellites: model.satellites)
                    .frame(height: 130)
            }
            .padding()
            .frame(minWidth: 340, idealWidth: 440)

            VStack(spacing: 10) {
                FixPanel()
                SatelliteTable(satellites: model.satellites)
            }
            .padding()
            .frame(minWidth: 520)
        }
    }
}

// MARK: - Sky plot

struct SkyView: View {
    let satellites: [Satellite]

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 22
            let c = CGPoint(x: size.width / 2, y: size.height / 2)

            // Elevation rings 0°, 30°, 60°
            for (i, el) in [0.0, 30, 60].enumerated() {
                let rr = r * (90 - el) / 90
                let rect = CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)
                ctx.stroke(Path(ellipseIn: rect), with: .color(.secondary.opacity(i == 0 ? 0.8 : 0.4)),
                           lineWidth: i == 0 ? 1.5 : 1)
                if i > 0 {
                    ctx.draw(Text("\(Int(el))°").font(.caption2).foregroundStyle(.secondary),
                             at: CGPoint(x: c.x + 3, y: c.y - rr + 7), anchor: .leading)
                }
            }
            // Azimuth spokes
            for az in stride(from: 0.0, to: 360, by: 30) {
                var p = Path()
                p.move(to: c)
                p.addLine(to: point(c, r, el: 0, az: az))
                ctx.stroke(p, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            }
            for (label, az) in [("N", 0.0), ("E", 90), ("S", 180), ("W", 270)] {
                ctx.draw(Text(label).font(.headline), at: point(c, r + 12, el: 0, az: az))
            }

            // Satellites
            for sat in satellites {
                guard let el = sat.el, let az = sat.az, el >= 0 else { continue }
                let p = point(c, r, el: el, az: az)
                let s: CGFloat = 20
                let rect = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
                let shape: Path = shapeFor(sat, in: rect)
                let color = snrColor(sat.ss)
                if sat.isUsed {
                    ctx.fill(shape, with: .color(color))
                    ctx.stroke(shape, with: .color(.primary.opacity(0.6)), lineWidth: 1)
                } else {
                    ctx.stroke(shape, with: .color(color), lineWidth: 2)
                }
                ctx.draw(Text("\(sat.prn)").font(.system(size: 9, weight: .bold)).foregroundStyle(sat.isUsed ? .black : .primary),
                         at: p)
            }
        }
        .accessibilityLabel("Sky view with \(satellites.count) satellites")
    }

    private func point(_ c: CGPoint, _ r: CGFloat, el: Double, az: Double) -> CGPoint {
        let rr = r * CGFloat((90 - el) / 90)
        let a = az * .pi / 180
        return CGPoint(x: c.x + rr * CGFloat(sin(a)), y: c.y - rr * CGFloat(cos(a)))
    }

    /// Different shapes per constellation, like xgps.
    private func shapeFor(_ sat: Satellite, in rect: CGRect) -> Path {
        switch sat.gnssName {
        case "GP", "QZ":
            return Path(ellipseIn: rect)
        case "GL":
            return Path(rect)
        case "GA":
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.closeSubpath()
            return p
        case "BD":
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY - 2))
            p.addLine(to: CGPoint(x: rect.maxX + 2, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX - 2, y: rect.maxY))
            p.closeSubpath()
            return p
        default:
            return Path(roundedRect: rect, cornerRadius: 5)
        }
    }
}

// MARK: - Signal bars

struct SignalBars: View {
    let satellites: [Satellite]

    var body: some View {
        GeometryReader { geo in
            let sats = Array(satellites.prefix(32))
            let w = sats.isEmpty ? 0 : min(36, geo.size.width / CGFloat(sats.count))
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(sats) { sat in
                    VStack(spacing: 2) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(snrColor(sat.ss).opacity(sat.isUsed ? 1 : 0.35))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(snrColor(sat.ss), lineWidth: sat.isUsed ? 0 : 1))
                            .frame(width: max(w - 3, 2),
                                   height: max(2, (geo.size.height - 16) * CGFloat(min(sat.ss ?? 0, 55) / 55)))
                        Text("\(sat.prn)").font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.5)
                            .frame(width: w)
                    }
                    .help("\(sat.gnssName) \(sat.prn): \(Fmt.num(sat.ss, "dBHz", digits: 0))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            Text("Signal (dBHz)").font(.caption2).foregroundStyle(.secondary).padding(6)
        }
    }
}

// MARK: - Fix data

struct FixPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.tpv
        let s = model.sky
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                row("Time (UTC)", Fmt.time(t))
                row("Latitude", Fmt.decimal(t.lat, pos: "N", neg: "S"), Fmt.dms(t.lat, pos: "N", neg: "S"))
                row("Longitude", Fmt.decimal(t.lon, pos: "E", neg: "W"), Fmt.dms(t.lon, pos: "E", neg: "W"))
                row("Altitude MSL", Fmt.num(t.altitudeMSL, "m"), "HAE: " + Fmt.num(t.altHAE, "m"))
                row("Speed", Fmt.num(t.speed.map { $0 * 3.6 }, "km/h"), t.speed.map { String(format: "%.2f m/s · %.1f kn", $0, $0 * 1.943844) } ?? "")
                row("Course", Fmt.num(t.track, "°"), "Climb: " + Fmt.num(t.climb, "m/s", digits: 2))
                row("Fix", t.modeDescription, "Satellites: \(s.usedCount) / \(s.visibleCount)")
                row(t.errorEstimated == true ? "Accuracy ≈" : "Accuracy",
                    "horiz. ± " + Fmt.num(t.eph ?? t.epx, "m"),
                    "vert. ± " + Fmt.num(t.epv, "m"))
                    .help(t.errorEstimated == true
                          ? "Estimated from DOP × typical range error (95 %), because the receiver sends no GST data"
                          : "Reported by the receiver (95 %)")
                row("DOP", String(format: "H %@  V %@  P %@", d(s.hdop), d(s.vdop), d(s.pdop)),
                    String(format: "T %@  G %@", d(s.tdop), d(s.gdop)))
            }
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Position").font(.headline)
                Spacer()
                Button { model.copyCoordinates() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(!t.hasFix)
                Button { model.openInMaps() } label: { Label("Open in Maps", systemImage: "map") }
                    .disabled(!t.hasFix)
            }
            .controlSize(.small)
        }
    }

    private func d(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }

    @ViewBuilder
    private func row(_ label: String, _ value: String, _ extra: String? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).font(.body)
            Text(value).textSelection(.enabled)
            Text(extra ?? "").foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

// MARK: - Satellite table

struct SatelliteTable: View {
    let satellites: [Satellite]

    var body: some View {
        Table(satellites) {
            TableColumn("GNSS") { Text($0.gnssName) }.width(44)
            TableColumn("PRN") { Text("\($0.prn)").monospacedDigit() }.width(44)
            TableColumn("Elev.") { Text(Fmt.num($0.el, "°", digits: 0)).monospacedDigit() }.width(54)
            TableColumn("Azim.") { Text(Fmt.num($0.az, "°", digits: 0)).monospacedDigit() }.width(54)
            TableColumn("SNR") { sat in
                HStack(spacing: 4) {
                    Circle().fill(snrColor(sat.ss)).frame(width: 8, height: 8)
                    Text(Fmt.num(sat.ss, "dB", digits: 0)).monospacedDigit()
                }
            }.width(70)
            TableColumn("Used") { sat in
                Image(systemName: sat.isUsed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(sat.isUsed ? .green : .secondary)
            }.width(56)
        }
    }
}
