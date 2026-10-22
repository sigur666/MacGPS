import Foundation
import Darwin

/// Reads an NMEA GPS receiver directly from a serial port – no gpsd required.
/// Detects the baud rate automatically and reconnects after the device is unplugged.
public final class SerialNMEAReader {
    public enum State: Equatable, Sendable {
        case stopped
        case opening
        case detecting(Int)
        case reading(Int)
        case failed(String)

        public var description: String {
            switch self {
            case .stopped: return "Stopped"
            case .opening: return "Opening port…"
            case .detecting(let b): return "Looking for NMEA data (\(b) baud)…"
            case .reading(let b): return "Receiving (\(b) baud)"
            case .failed(let m): return m
            }
        }
        public var isActive: Bool { self != .stopped }
        public var isReading: Bool { if case .reading = self { return true }; return false }
    }

    /// Order matters: the most common rates are tried first.
    public static let baudRates = [9600, 4800, 38400, 115200, 57600, 19200, 230400]

    public var onState: ((State) -> Void)?
    public var onTPV: ((TPV) -> Void)?
    public var onSKY: ((SKY) -> Void)?
    public var onRaw: ((String) -> Void)?
    public var callbackQueue: DispatchQueue

    private let queue = DispatchQueue(label: "macgps.serial")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var path = ""
    private var fixedBaud: Int?
    private var candidates: [Int] = []
    private var currentBaud = 0
    private var locked = false
    private var running = false
    private var generation = 0
    private var buffer = Data()
    private var parser = NMEAParser()
    private var pending: NMEAParser.Changes = []
    private var flushScheduled = false

    public init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
    }

    /// - Parameter baud: fixed baud rate, or nil for automatic detection.
    public func start(path: String, baud: Int? = nil) {
        queue.async {
            self.closePort()
            self.running = true
            self.path = path
            self.fixedBaud = baud
            self.openPort()
        }
    }

    public func stop() {
        queue.async {
            self.running = false
            self.closePort()
            self.setState(.stopped)
        }
    }

    // MARK: - Private

    private func setState(_ s: State) { callbackQueue.async { self.onState?(s) } }

    private func openPort() {
        guard running else { return }
        setState(.opening)
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else {
            let err = errno
            fail(err == EBUSY ? "\(path) is busy (is gpsd still running?)" : "\(path): \(String(cString: strerror(err)))")
            return
        }
        _ = ioctl(f, 0x2000_740D) // TIOCEXCL: exclusive access, like gpsd
        fd = f
        parser = NMEAParser(device: path)
        candidates = []
        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { close(f) }
        source = src
        src.resume()
        tryNextBaud()
    }

    private func closePort() {
        generation += 1
        source?.cancel()
        source = nil
        fd = -1
        buffer.removeAll()
        locked = false
    }

    private func fail(_ message: String) {
        closePort()
        setState(.failed(message))
        guard running else { return }
        let gen = generation
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.running, self.generation == gen, self.fd < 0 else { return }
            self.openPort()
        }
    }

    private func configure(baud: Int) {
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        cfsetspeed(&t, speed_t(baud))
        tcsetattr(fd, TCSANOW, &t)
        tcflush(fd, TCIOFLUSH)
    }

    private func tryNextBaud() {
        guard running, fd >= 0 else { return }
        if candidates.isEmpty { candidates = fixedBaud.map { [$0] } ?? Self.baudRates }
        currentBaud = candidates.removeFirst()
        configure(baud: currentBaud)
        locked = false
        buffer.removeAll()
        generation += 1
        let gen = generation
        setState(.detecting(currentBaud))
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.generation == gen, !self.locked else { return }
            self.tryNextBaud()
        }
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &chunk, chunk.count)
        if n > 0 {
            buffer.append(contentsOf: chunk[0..<n])
            processLines()
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            fail("Device disconnected: \(path)")
        }
    }

    private func processLines() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { continue }
            guard NMEAParser.validatedFields(line) != nil else { continue }
            if !locked {
                locked = true
                setState(.reading(currentBaud))
            }
            if let onRaw { callbackQueue.async { onRaw(line) } }
            pending.formUnion(parser.feed(line))
        }
        // Wrong baud rate produces garbage without newlines.
        if buffer.count > 4096 { buffer.removeAll() }
        scheduleFlush()
    }

    /// Coalesce all sentences of one epoch into a single TPV/SKY pair.
    private func scheduleFlush() {
        guard !pending.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let changes = self.pending
            self.pending = []
            let sky = changes.contains(.sky) ? self.parser.sky : nil
            let tpv = changes.contains(.tpv) ? self.parser.tpv : nil
            self.callbackQueue.async {
                if let sky { self.onSKY?(sky) }
                if let tpv { self.onTPV?(tpv) }
            }
        }
    }
}
