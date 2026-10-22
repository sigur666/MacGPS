import Foundation
import Darwin

/// Starts and stops a gpsd daemon and inspects the system for GPS receivers.
public final class GPSDController {
    public enum ControlError: LocalizedError {
        case gpsdNotFound
        case noDevice
        case alreadyRunning
        case stopFailed(String)

        public var errorDescription: String? {
            switch self {
            case .gpsdNotFound: return "gpsd not found. Install it with: brew install gpsd"
            case .noDevice: return "No GPS receiver selected."
            case .alreadyRunning: return "gpsd is already running."
            case .stopFailed(let msg): return "Could not stop gpsd: \(msg)"
            }
        }
    }

    public static let searchPaths = [
        "/opt/homebrew/sbin/gpsd", "/opt/homebrew/bin/gpsd",
        "/usr/local/sbin/gpsd", "/usr/local/bin/gpsd",
        "/opt/local/sbin/gpsd", "/usr/sbin/gpsd",
    ]

    /// Output lines of the managed gpsd (stdout + stderr).
    public var onOutput: ((String) -> Void)?
    /// Called when the managed gpsd process exits.
    public var onExit: ((Int32) -> Void)?
    public var callbackQueue: DispatchQueue = .main

    public private(set) var process: Process?
    public var isManagedRunning: Bool { process?.isRunning ?? false }

    public init() {}

    public static func findGPSD(customPath: String? = nil) -> String? {
        let fm = FileManager.default
        if let customPath, !customPath.isEmpty, fm.isExecutableFile(atPath: customPath) { return customPath }
        return searchPaths.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Serial devices that may be GPS receivers (/dev/cu.*), noise filtered out.
    public static func serialDevices() -> [String] {
        let ignored = ["Bluetooth-Incoming-Port", "debug-console", "wlan-debug"]
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return entries
            .filter { $0.hasPrefix("cu.") && !ignored.contains(where: $0.contains) }
            .map { "/dev/" + $0 }
            .sorted { lhs, rhs in
                // Likely GPS receivers (USB serial) first
                let score: (String) -> Int = { $0.contains("usb") ? 0 : 1 }
                return (score(lhs), lhs) < (score(rhs), rhs)
            }
    }

    /// True if something accepts TCP connections on 127.0.0.1:port.
    public static func isListening(port: UInt16 = 2947) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Launch gpsd in the foreground (-N) so it is owned by this process.
    public func start(device: String, port: UInt16 = 2947, gpsdPath: String? = nil,
                      listenOnLAN: Bool = false, extraArguments: [String] = []) throws {
        guard !isManagedRunning else { throw ControlError.alreadyRunning }
        guard let path = Self.findGPSD(customPath: gpsdPath) else { throw ControlError.gpsdNotFound }
        guard !device.isEmpty else { throw ControlError.noDevice }

        let control = FileManager.default.temporaryDirectory.appendingPathComponent("macgps-gpsd.sock").path
        var args = ["-N", "-n", "-S", String(port), "-F", control]
        if listenOnLAN { args.append("-G") }
        args += extraArguments
        args.append(device)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            self.callbackQueue.async { lines.forEach { self.onOutput?($0) } }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            let code = proc.terminationStatus
            self.callbackQueue.async {
                if self.process === proc { self.process = nil }
                self.onExit?(code)
            }
        }
        callbackQueue.async { self.onOutput?("$ \(path) \(args.joined(separator: " "))") }
        try p.run()
        process = p
    }

    /// Stop gpsd. Stops the managed process, or – if gpsd was started elsewhere – tries `pkill -x gpsd`.
    public func stop() throws {
        if let p = process, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            return
        }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-x", "gpsd"]
        let err = Pipe()
        pkill.standardError = err
        try pkill.run()
        pkill.waitUntilExit()
        if pkill.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ControlError.stopFailed(msg.isEmpty
                ? "Permission denied – gpsd is probably running as root (e.g. via launchd/brew services). Stop it with: sudo brew services stop gpsd"
                : msg)
        }
    }
}
