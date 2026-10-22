import Foundation
import Darwin

/// Virtual serial port: creates a pseudo terminal and writes NMEA into it.
/// Any macOS app that expects a serial GPS mouse can open the symlink (e.g. /tmp/gps-nmea).
public final class PTYBridge {
    public enum PTYError: LocalizedError {
        case openFailed(String)
        public var errorDescription: String? {
            if case .openFailed(let m) = self { return "Virtual port: \(m)" }
            return nil
        }
    }

    private var master: Int32 = -1
    private var slave: Int32 = -1
    private let lock = NSLock()
    public private(set) var deviceName: String?
    public private(set) var linkPath: String?

    public init() {}
    public var isRunning: Bool { lock.withLock { master >= 0 } }

    public func start(linkPath: String) throws {
        stop()
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0, grantpt(m) == 0, unlockpt(m) == 0, let namePtr = ptsname(m) else {
            if m >= 0 { close(m) }
            throw PTYError.openFailed(String(cString: strerror(errno)))
        }
        let name = String(cString: namePtr)
        // Keep the slave side open so writes never fail with EIO when no reader is attached.
        let s = open(name, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard s >= 0 else { close(m); throw PTYError.openFailed(String(cString: strerror(errno))) }

        var t = termios()
        tcgetattr(s, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B9600))
        tcsetattr(s, TCSANOW, &t)
        _ = fcntl(m, F_SETFL, fcntl(m, F_GETFL) | O_NONBLOCK)

        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil || fm.fileExists(atPath: linkPath) {
            try? fm.removeItem(atPath: linkPath)
        }
        do {
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: name)
        } catch {
            close(s); close(m)
            throw PTYError.openFailed("Symlink \(linkPath): \(error.localizedDescription)")
        }
        lock.withLock {
            master = m; slave = s
            deviceName = name; self.linkPath = linkPath
        }
    }

    public func send(_ text: String) {
        lock.withLock {
            guard master >= 0 else { return }
            let bytes = Array(text.utf8)
            let written = bytes.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count) }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Nobody is reading: drop the stale backlog so a new reader gets fresh data.
                tcflush(slave, TCIFLUSH)
            }
        }
    }

    public func stop() {
        lock.withLock {
            if master >= 0 { close(master) }
            if slave >= 0 { close(slave) }
            master = -1; slave = -1
            if let linkPath { try? FileManager.default.removeItem(atPath: linkPath) }
            linkPath = nil; deviceName = nil
        }
    }

    deinit { stop() }
}
