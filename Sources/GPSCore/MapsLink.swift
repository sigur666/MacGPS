import Foundation

public enum MapsLink {
    /// Apple Maps URL that drops a pin at the given coordinate.
    /// Built with URLComponents so the label is escaped correctly (no format strings).
    public static func url(latitude: Double, longitude: Double, label: String = "GPS Position") -> URL? {
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [
            URLQueryItem(name: "ll", value: String(format: "%.7f,%.7f", latitude, longitude)),
            URLQueryItem(name: "q", value: label),
        ]
        return c?.url
    }
}
