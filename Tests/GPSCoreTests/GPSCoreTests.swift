import Foundation
import Testing
@testable import GPSCore

@Test func checksumMatchesKnownSentence() {
    // Well-known example sentence
    #expect(NMEA.checksum("GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,") == "47")
}

@Test func coordinateFormatting() {
    let (lat, ns) = NMEA.coordinate(48.1173, degreeDigits: 2, pos: "N", neg: "S")
    #expect(lat == "4807.03800" && ns == "N")
    let (lon, ew) = NMEA.coordinate(-11.516666667, degreeDigits: 3, pos: "E", neg: "W")
    #expect(lon == "01131.00000" && ew == "W")
}

@Test func decodesTPVAndSKY() throws {
    let tpvJSON = #"{"class":"TPV","device":"/dev/x","mode":3,"time":"2026-10-11T12:34:56.500Z","lat":48.1,"lon":11.5,"altHAE":560.1,"altMSL":512.3,"speed":1.5,"track":90.0}"#
    let tpv = try JSONDecoder().decode(TPV.self, from: Data(tpvJSON.utf8))
    #expect(tpv.hasFix)
    #expect(tpv.date != nil)

    let skyJSON = #"{"class":"SKY","hdop":0.9,"pdop":1.5,"vdop":1.2,"satellites":[{"PRN":5,"el":45,"az":120,"ss":42,"used":true,"gnssid":0,"svid":5},{"PRN":70,"el":10,"az":300,"ss":20,"used":false,"gnssid":6,"svid":6}]}"#
    let sky = try JSONDecoder().decode(SKY.self, from: Data(skyJSON.utf8))
    #expect(sky.usedCount == 1 && sky.visibleCount == 2)
    #expect(sky.satellites?[1].gnssName == "GL")

    let sentences = NMEA.sentences(tpv: tpv, sky: sky)
    #expect(sentences.first?.hasPrefix("$GPGGA,123456.50,4806.00000,N,01130.00000,E,1,01,0.90,512.3,M,47.8,M,,*") == true)
    #expect(sentences.contains { $0.hasPrefix("$GPRMC,123456.50,A,") && $0.contains(",111026,") })
    for s in sentences {
        let body = s.dropFirst().split(separator: "*")[0]
        let cs = s.split(separator: "*")[1].prefix(2)
        #expect(NMEA.checksum(String(body)) == String(cs))
    }
}

// MARK: - Direct NMEA

private let sampleEpoch = [
    "$GNRMC,123519.00,A,4807.03800,N,01131.00000,E,10.0,84.4,230394,,,A,V*",
    "$GNGGA,123519.00,4807.03800,N,01131.00000,E,1,08,0.9,545.4,M,46.9,M,,*",
    "$GNGSA,A,3,04,05,09,12,,,,,,,,,1.8,0.9,1.5,1*",
    "$GNGSA,A,3,70,71,,,,,,,,,,,1.8,0.9,1.5,2*",
    "$GPGSV,2,1,05,04,40,083,46,05,17,308,41,09,72,231,44,12,07,344,39,1*",
    "$GPGSV,2,2,05,25,10,120,,1*",
    "$GLGSV,1,1,02,70,55,010,38,71,30,200,35,1*",
    "$GNGST,123519.00,1.2,,,,1.5,2.0,3.1*",
].map { s -> String in
    let body = String(s.dropFirst().dropLast())
    return "$\(body)*\(NMEA.checksum(body))"
}

@Test func rejectsBadChecksum() {
    #expect(NMEAParser.validatedFields("$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47") != nil)
    #expect(NMEAParser.validatedFields("$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*48") == nil)
    #expect(NMEAParser.validatedFields("garbage") == nil)
}

@Test func parsesFullEpoch() throws {
    var p = NMEAParser(device: "/dev/test")
    sampleEpoch.forEach { p.feed($0) }
    let tpv = p.tpv
    #expect(tpv.mode == 3)
    #expect(abs((tpv.lat ?? 0) - 48.1173) < 1e-6)
    #expect(abs((tpv.lon ?? 0) - 11.516666667) < 1e-6)
    #expect(tpv.altMSL == 545.4)
    #expect(abs((tpv.altHAE ?? 0) - 592.3) < 1e-9)
    #expect(abs((tpv.speed ?? 0) - 10.0 / 1.943844492) < 1e-6)
    #expect(tpv.time == "1994-03-23T12:35:19.00Z")
    #expect(tpv.date != nil)
    #expect(tpv.epx == 4.0 && tpv.epy == 3.0 && abs((tpv.epv ?? 0) - 6.2) < 1e-9)
    #expect(abs((tpv.eph ?? 0) - 5.0) < 1e-9)
    #expect(tpv.errorEstimated == false)

    let sky = p.sky
    #expect(sky.visibleCount == 7)
    #expect(sky.usedCount == 6)
    #expect(sky.hdop == 0.9 && sky.pdop == 1.8)
    let glo = try #require(sky.satellites?.first { $0.prn == 70 })
    #expect(glo.gnssName == "GL" && glo.isUsed)
    let unused = try #require(sky.satellites?.first { $0.prn == 25 })
    #expect(!unused.isUsed && unused.ss == nil)
}

@Test func noFixWhenInvalid() {
    var p = NMEAParser()
    for s in ["GPRMC,000001.00,V,,,,,,,010125,,,N", "GPGGA,000001.00,,,,,0,00,99.99,,,,,,"] {
        p.feed("$\(s)*\(NMEA.checksum(s))")
    }
    #expect(p.tpv.mode == 1)
    #expect(!p.tpv.hasFix)
}

@Test func serialReaderReadsFromPTY() async throws {
    // A pseudo terminal stands in for a USB GPS receiver.
    let master = posix_openpt(O_RDWR | O_NOCTTY)
    #expect(master >= 0)
    grantpt(master); unlockpt(master)
    let slavePath = String(cString: ptsname(master))
    defer { close(master) }

    let reader = SerialNMEAReader(callbackQueue: DispatchQueue(label: "test"))
    let got = try await withThrowingTaskGroup(of: TPV?.self) { group in
        group.addTask {
            await withCheckedContinuation { (cont: CheckedContinuation<TPV?, Never>) in
                let once = OnceFlag()
                reader.onTPV = { tpv in if tpv.hasFix, once.claim() { cont.resume(returning: tpv) } }
                reader.start(path: slavePath)
                DispatchQueue.global().async {
                    for _ in 0..<20 {
                        let text = sampleEpoch.map { $0 + "\r\n" }.joined()
                        _ = text.withCString { write(master, $0, strlen($0)) }
                        usleep(200_000)
                    }
                    if once.claim() { cont.resume(returning: nil) }
                }
            }
        }
        let r = try await group.next() ?? nil
        group.cancelAll()
        return r
    }
    reader.stop()
    let tpv = try #require(got)
    #expect(abs((tpv.lat ?? 0) - 48.1173) < 1e-6)
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

@Test func estimatesAccuracyWithoutGST() {
    // u-blox 7 default output: no GST sentence
    var p = NMEAParser()
    for s in ["GPRMC,220016.00,A,5230.97650,N,01322.66224,E,0.285,,111026,,,A",
              "GPGGA,220016.00,5230.97650,N,01322.66224,E,1,05,2.04,185.1,M,43.7,M,,",
              "GPGSA,A,3,18,29,16,05,26,,,,,,,,3.73,2.04,3.12"] {
        p.feed("$\(s)*\(NMEA.checksum(s))")
    }
    let t = p.tpv
    #expect(t.errorEstimated == true)
    #expect(abs((t.eph ?? 0) - 2 * 2.04 * 4.0) < 1e-9)   // 16.3 m
    #expect(abs((t.epv ?? 0) - 2 * 3.12 * 4.0) < 1e-9)   // 25.0 m
    #expect(Position(tpv: t, sky: nil).accuracySource == "estimated (DOP × UERE)")

    // No fix → no accuracy
    var q = NMEAParser()
    let s = "GPGGA,,,,,,0,00,99.99,,,,,,"
    q.feed("$\(s)*\(NMEA.checksum(s))")
    #expect(q.tpv.eph == nil)
}

@Test func mapsLinkIsEscaped() throws {
    let url = try #require(MapsLink.url(latitude: 52.516275, longitude: -13.377704))
    #expect(url.absoluteString == "https://maps.apple.com/?ll=52.5162750,-13.3777040&q=GPS%20Position")
}
