import Combine
import Foundation

public final class SGPort: Hashable, Identifiable {
    private var fileDescriptor: Int32 = 0
    private var originalPortOptions = termios()
    private var readTimer: DispatchSourceTimer?
    private var isClosing = false

    public private(set) var name: String = ""
    public private(set) var state: SGPortState = .closed
    public private(set) var baudRate: Int32 = B9600
    public private(set) var parity: SGParity = .none
    public private(set) var stopBits: UInt32 = 1

    public var id: String { name }

    // MARK: Publisher
    private let changedPortStateSubject = PassthroughSubject<SGPortState, Never>()
    public var changedPortStatePublisher: AnyPublisher<SGPortState, Never> {
        return changedPortStateSubject.eraseToAnyPublisher()
    }

    private let receivedTextSubject = PassthroughSubject<(SGError?, String?), Never>()
    public var receivedTextPublisher: AnyPublisher<(SGError?, String?), Never> {
        return receivedTextSubject.eraseToAnyPublisher()
    }
    
    private let receivedDataSubject = PassthroughSubject<(SGError?, Data?), Never>()
    public var receivedDataPublisher: AnyPublisher<(SGError?, Data?), Never> {
        return receivedDataSubject.eraseToAnyPublisher()
    }

    init(_ portName: String) {
        name = portName
    }

    deinit {
        try? close()
    }

    // MARK: Public Function
    public func open() throws {
        var fd: Int32 = -1

        fd = Darwin.open(name.cString(using: .ascii)!, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd == -1 {
            throw SGError.couldNotOpenPort(name)
        }
        if fcntl(fd, F_SETFL, 0) == -1 {
            throw SGError.couldNotOpenPort(name)
        }

        // ★★★ Start Communication ★★★ //
        fileDescriptor = fd
        try setOptions()
        readTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        readTimer?.schedule(
            deadline: DispatchTime.now(),
            repeating: DispatchTimeInterval.nanoseconds(Int(10 * NSEC_PER_MSEC)),
            leeway: DispatchTimeInterval.nanoseconds(Int(5 * NSEC_PER_MSEC))
        )
        readTimer?.setEventHandler(handler: { [weak self] in
            self?.read()
        })
        readTimer?.setCancelHandler(handler: { [weak self] in
            do {
                try self?.close()
            } catch {
                logput(error.localizedDescription)
            }
        })
        readTimer?.resume()
        state = SGPortState.open
        changedPortStateSubject.send(.open)
    }

    public func close() throws {
        guard !isClosing && state != .closed else { return }
        isClosing = true
        
        readTimer?.cancel()
        readTimer = nil
        if tcdrain(fileDescriptor) == -1 {
            isClosing = false
            throw SGError.couldNotClosePort(name)
        }
        var options = termios()
        if tcsetattr(fileDescriptor, TCSADRAIN, &options) == -1 {
            isClosing = false
            throw SGError.couldNotClosePort(name)
        }
        Darwin.close(fileDescriptor)
        state = SGPortState.closed
        fileDescriptor = -1
        changedPortStateSubject.send(.closed)
        isClosing = false
    }

    public func send(_ text: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw SGError.encodingFailed("Failed to encode string: '\(text)' as UTF-8")
        }
        let _ = try sendData(data)
    }

    public func sendData(_ data: Data) throws -> Int {
        if state != .open {
            throw SGError.portIsNotOpen(name)
        }
        return try data.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else {
                throw SGError.invalidData
            }
            return try writeBytes(baseAddress, count: data.count)
        }
    }

    private func writeBytes(_ pointer: UnsafeRawPointer, count: Int) throws -> Int {
        let bytesWritten = Darwin.write(fileDescriptor, pointer, count)
        if bytesWritten == -1 {
            throw SGError.writeFailed(errno)
        }
        return bytesWritten
    }

    // MARK: Set Options
    private func setOptions() throws {
        if fileDescriptor < 1 { return }
        var options = termios()
        if tcgetattr(fileDescriptor, &options) == -1 {
            throw SGError.couldNotSetOptions(name)
        }
        cfmakeraw(&options)
        options.updateC_CC(VMIN, v: 1)
        options.updateC_CC(VTIME, v: 2)

        // DataBits
        options.c_cflag &= ~UInt(CSIZE)
        options.c_cflag |= UInt(CS8)

        // StopBits
        if 1 < stopBits {
            options.c_cflag |= UInt(CSTOPB)
        } else {
            options.c_cflag &= ~UInt(CSTOPB)
        }

        // Parity
        switch parity {
        case .none:
            options.c_cflag &= ~UInt(PARENB)
        case .even:
            options.c_cflag |= UInt(PARENB)
            options.c_cflag &= ~UInt(PARODD)
        case .odd:
            options.c_cflag |= UInt(PARENB)
            options.c_cflag |= UInt(PARODD)
        }

        // EchoReceivedData
        options.c_cflag &= ~UInt(ECHO)
        // RTS CTS FlowControl
        options.c_cflag &= ~UInt(CRTSCTS)
        // DTR DSR FlowControl
        options.c_cflag &= ~UInt(CDTR_IFLOW | CDSR_OFLOW)
        // DCD OutputFlowControl
        options.c_cflag &= ~UInt(CCAR_OFLOW)

        options.c_cflag |= UInt(HUPCL)
        options.c_cflag |= UInt(CLOCAL)
        options.c_cflag |= UInt(CREAD)
        options.c_lflag &= ~UInt(ICANON | ISIG)

        cfsetspeed(&options, speed_t(baudRate))

        if tcsetattr(fileDescriptor, TCSANOW, &options) == -1 {
            throw SGError.couldNotSetOptions(name)
        }
    }

    public func setBaudRate(_ baudRate: Int32) throws {
        let previousBaudRate = self.baudRate
        self.baudRate = baudRate
        do {
            try setOptions()
        } catch {
            self.baudRate = previousBaudRate
            throw error
        }
    }

    public func setParity(_ parity: SGParity) throws {
        let previousParity = self.parity
        self.parity = parity
        do {
            try setOptions()
        } catch {
            self.parity = previousParity
            throw error
        }
    }

    public func setStopBits(_ stopBits: UInt32) throws {
        let previousStopBits = self.stopBits
        self.stopBits = stopBits
        do {
            try setOptions()
        } catch {
            self.stopBits = previousStopBits
            throw error
        }
    }

    // MARK: Internal Function
    func removed() {
        readTimer?.cancel()
        readTimer = nil
        if tcdrain(fileDescriptor) == -1 { return }
        if tcsetattr(fileDescriptor, TCSADRAIN, &originalPortOptions) == -1 { return }
        Darwin.close(fileDescriptor)
        state = SGPortState.removed
        changedPortStateSubject.send(.removed)
    }

    func fallSleep() {
        readTimer?.suspend()
        state = SGPortState.sleeping
    }

    func wakeUp() {
        readTimer?.resume()
        state = SGPortState.open
    }

    // MARK: Private Function
    private func read() {
        guard state == .open else {
            receivedDataSubject.send((SGError.portIsNotOpen(name), nil))
            receivedTextSubject.send((SGError.portIsNotOpen(name), nil))
            return
        }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let readLength = Darwin.read(fileDescriptor, &buffer, 1024)
        if readLength < 1 { return }
        let data = Data(bytes: buffer, count: readLength)
        
        receivedDataSubject.send((nil, data))
        
        let text = String(data: data, encoding: .ascii)!
        receivedTextSubject.send((nil, text))
        
        if let text = String(data: data, encoding: .ascii) {
            receivedTextSubject.send((nil, text))
        } else {
            receivedTextSubject.send((SGError.encodingFailed("Failed to decode data as ASCII string"), nil))
        }
    }

    // MARK: Equatable
    public static func == (lhs: SGPort, rhs: SGPort) -> Bool {
        return lhs === rhs
    }

    // MARK: Hashable
    public func hash(into hasher: inout Hasher) {
        ObjectIdentifier(self).hash(into: &hasher)
    }
}
