import Foundation

/// Errors surfaced by the Solarman V5 client.
enum SolarmanError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case timeout
    case shortRead
    case v5Frame(String)
    case modbus(String)

    var description: String {
        switch self {
        case .connectionFailed(let s): return "connection failed: \(s)"
        case .timeout: return "timeout"
        case .shortRead: return "short read"
        case .v5Frame(let s): return "v5 frame error: \(s)"
        case .modbus(let s): return "modbus error: \(s)"
        }
    }
}

/// Synchronous Solarman V5 client over a raw POSIX TCP socket.
///
/// Mirrors pysolarmanv5 framing byte-for-byte: V5 wrapper around a Modbus RTU
/// "read holding registers" (function 0x03) request. Requests are strictly
/// sequential (send -> read full response -> next). One connection is reused
/// across polls; call `close()` and reconnect on any error/timeout.
final class SolarmanClient {
    let host: String
    let port: UInt16
    let loggerSerial: UInt32
    let slaveId: UInt8
    let timeout: TimeInterval

    private var fd: Int32 = -1
    private var sequence: UInt8 = UInt8.random(in: 1...254)

    init(host: String, port: UInt16, loggerSerial: UInt32, slaveId: UInt8, timeout: TimeInterval = 3.0) {
        self.host = host
        self.port = port
        self.loggerSerial = loggerSerial
        self.slaveId = slaveId
        self.timeout = timeout
    }

    deinit {
        close()
    }

    var isConnected: Bool { fd >= 0 }

    // MARK: - Connection

    func connect() throws {
        close()

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        let status = getaddrinfo(host, portStr, &hints, &result)
        guard status == 0, let addrInfo = result else {
            throw SolarmanError.connectionFailed("getaddrinfo: \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(result) }

        var lastErr = "no address"
        var ai: UnsafeMutablePointer<addrinfo>? = addrInfo
        while let node = ai {
            let sock = socket(node.pointee.ai_family, node.pointee.ai_socktype, node.pointee.ai_protocol)
            if sock < 0 {
                lastErr = String(cString: strerror(errno))
                ai = node.pointee.ai_next
                continue
            }

            // Blocking connect with socket-level timeouts applied afterwards.
            if Foundation.connect(sock, node.pointee.ai_addr, node.pointee.ai_addrlen) == 0 {
                fd = sock
                applyTimeouts()
                var one: Int32 = 1
                setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                return
            }
            lastErr = String(cString: strerror(errno))
            Foundation.close(sock)
            ai = node.pointee.ai_next
        }
        throw SolarmanError.connectionFailed(lastErr)
    }

    private func applyTimeouts() {
        let usec = __darwin_suseconds_t((timeout - Double(Int(timeout))) * 1_000_000)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: usec)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func close() {
        if fd >= 0 {
            Foundation.close(fd)
            fd = -1
        }
    }

    // MARK: - Public API

    /// Read `quantity` holding registers starting at `startReg` (Modbus func 0x03).
    /// Returns register values as UInt16 (big-endian in the wire, decoded here).
    func readHoldingRegisters(start startReg: UInt16, quantity: UInt16) throws -> [UInt16] {
        if fd < 0 { try connect() }

        let mbRequest = buildModbusReadRequest(start: startReg, count: quantity)
        let v5Request = encodeV5Frame(modbusFrame: mbRequest)
        try sendAll(v5Request)
        let v5Response = try receiveV5Frame()
        let mbResponse = try decodeV5Frame(v5Response)
        return try parseModbusResponse(mbResponse, expectedCount: quantity)
    }

    // MARK: - Modbus RTU

    /// Build a Modbus RTU "read holding registers" request:
    /// slave(1) func(0x03) startReg(u16 BE) count(u16 BE) crc16(u16 LE).
    private func buildModbusReadRequest(start: UInt16, count: UInt16) -> [UInt8] {
        var frame: [UInt8] = [
            slaveId,
            0x03,
            UInt8(start >> 8), UInt8(start & 0xFF),
            UInt8(count >> 8), UInt8(count & 0xFF)
        ]
        let crc = modbusCRC16(frame)
        frame.append(UInt8(crc & 0xFF))       // CRC low byte first (LE)
        frame.append(UInt8(crc >> 8))
        return frame
    }

    /// Modbus CRC-16 (poly 0xA001, init 0xFFFF).
    private func modbusCRC16(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 0x0001 != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    /// Parse a Modbus RTU read-holding-registers response into register values.
    /// Response: slave(1) func(1) byteCount(1) data(2*n BE) crc(2 LE).
    private func parseModbusResponse(_ frame: [UInt8], expectedCount: UInt16) throws -> [UInt16] {
        guard frame.count >= 5 else {
            throw SolarmanError.modbus("response too short (\(frame.count) bytes)")
        }
        // Exception response: func code has high bit set.
        if frame[1] & 0x80 != 0 {
            let code = frame.count > 2 ? frame[2] : 0
            throw SolarmanError.modbus("modbus exception code \(code)")
        }
        guard frame[1] == 0x03 else {
            throw SolarmanError.modbus("unexpected function code \(frame[1])")
        }
        let byteCount = Int(frame[2])
        guard frame.count >= 3 + byteCount + 2 else {
            throw SolarmanError.modbus("declared byteCount \(byteCount) exceeds frame")
        }
        // Verify CRC over everything up to (not including) the trailing CRC.
        let crcStart = 3 + byteCount
        let body = Array(frame[0..<crcStart])
        let expectedCRC = modbusCRC16(body)
        let actualCRC = UInt16(frame[crcStart]) | (UInt16(frame[crcStart + 1]) << 8)
        guard expectedCRC == actualCRC else {
            throw SolarmanError.modbus("modbus CRC mismatch")
        }

        var registers: [UInt16] = []
        registers.reserveCapacity(byteCount / 2)
        var i = 3
        while i + 1 < crcStart {
            registers.append((UInt16(frame[i]) << 8) | UInt16(frame[i + 1]))
            i += 2
        }
        return registers
    }

    // MARK: - Solarman V5 framing

    private func nextSequence() -> UInt8 {
        sequence = sequence &+ 1
        return sequence
    }

    /// Wrap a Modbus RTU frame in a Solarman V5 request frame.
    ///
    /// A5 <len u16 LE> <control u16 LE=0x4510> <seq u16 LE> <loggerSerial u32 LE>
    /// <payload> <checksum u8> 15
    /// payload = frameType(0x02) sensorType(0x0000) deliveryTime(u32=0)
    ///           powerOnTime(u32=0) offsetTime(u32=0) + modbusFrame
    /// len = payload length = 15 + modbusFrame.count
    /// checksum = sum of bytes between (excluding) A5 and checksum, & 0xFF
    private func encodeV5Frame(modbusFrame: [UInt8]) -> [UInt8] {
        let payloadLen = UInt16(15 + modbusFrame.count)
        let seq = UInt16(nextSequence())

        var frame: [UInt8] = []
        frame.append(0xA5)                                          // start
        frame.append(UInt8(payloadLen & 0xFF))                     // length LE
        frame.append(UInt8(payloadLen >> 8))
        frame.append(0x10); frame.append(0x45)                     // control 0x4510 LE
        frame.append(UInt8(seq & 0xFF)); frame.append(UInt8(seq >> 8)) // sequence LE
        frame.append(UInt8(loggerSerial & 0xFF))                   // loggerSerial LE
        frame.append(UInt8((loggerSerial >> 8) & 0xFF))
        frame.append(UInt8((loggerSerial >> 16) & 0xFF))
        frame.append(UInt8((loggerSerial >> 24) & 0xFF))
        // payload
        frame.append(0x02)                                         // frameType
        frame.append(0x00); frame.append(0x00)                     // sensorType
        frame.append(contentsOf: [0, 0, 0, 0])                     // deliveryTime
        frame.append(contentsOf: [0, 0, 0, 0])                     // powerOnTime
        frame.append(contentsOf: [0, 0, 0, 0])                     // offsetTime
        frame.append(contentsOf: modbusFrame)
        // trailer
        frame.append(0x00)                                         // checksum placeholder
        frame.append(0x15)                                         // end

        // checksum = sum(frame[1 ..< len-2]) & 0xFF
        var checksum: UInt32 = 0
        for i in 1..<(frame.count - 2) {
            checksum += UInt32(frame[i])
        }
        frame[frame.count - 2] = UInt8(checksum & 0xFF)
        return frame
    }

    private func v5FrameChecksum(_ frame: [UInt8]) -> UInt8 {
        var checksum: UInt32 = 0
        for i in 1..<(frame.count - 2) {
            checksum += UInt32(frame[i])
        }
        return UInt8(checksum & 0xFF)
    }

    /// Validate a V5 response frame and extract the inner Modbus RTU frame.
    /// Response control code is 0x1510; the modbus RTU answer begins at offset 25
    /// (header 11 + response payload preamble 14: frameType(1) status(1)
    /// totalTime(4) powerOnTime(4) offsetTime(4)).
    private func decodeV5Frame(_ frame: [UInt8]) throws -> [UInt8] {
        guard frame.count >= 28 else {
            throw SolarmanError.v5Frame("frame too short (\(frame.count) bytes)")
        }
        let payloadLen = Int(frame[1]) | (Int(frame[2]) << 8)
        let frameLen = 13 + payloadLen
        guard frameLen <= frame.count else {
            throw SolarmanError.v5Frame("declared length \(frameLen) exceeds received \(frame.count)")
        }
        guard frame[0] == 0xA5, frame[frameLen - 1] == 0x15 else {
            throw SolarmanError.v5Frame("invalid start/end")
        }
        let expectedChecksum = v5FrameChecksum(Array(frame[0..<frameLen]))
        guard frame[frameLen - 2] == expectedChecksum else {
            throw SolarmanError.v5Frame("invalid V5 checksum")
        }
        guard frame[5] == sequence else {
            throw SolarmanError.v5Frame("sequence mismatch (got \(frame[5]), want \(sequence))")
        }
        // loggerSerial echo (LE at bytes 7..10)
        let echoedSerial = UInt32(frame[7]) | (UInt32(frame[8]) << 8) | (UInt32(frame[9]) << 16) | (UInt32(frame[10]) << 24)
        guard echoedSerial == loggerSerial else {
            throw SolarmanError.v5Frame("logger serial mismatch")
        }
        guard frame[3] == 0x10, frame[4] == 0x15 else {
            throw SolarmanError.v5Frame("invalid control code")
        }
        guard frame[11] == 0x02 else {
            throw SolarmanError.v5Frame("invalid frametype")
        }
        let modbus = Array(frame[25..<(frameLen - 2)])
        guard modbus.count >= 5 else {
            throw SolarmanError.v5Frame("no valid modbus RTU frame")
        }
        return modbus
    }

    // MARK: - Socket IO

    private func sendAll(_ bytes: [UInt8]) throws {
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            while offset < bytes.count {
                let n = Foundation.send(fd, base + offset, bytes.count - offset, 0)
                if n > 0 {
                    offset += n
                } else if n == 0 {
                    throw SolarmanError.connectionFailed("send returned 0")
                } else {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw SolarmanError.timeout }
                    throw SolarmanError.connectionFailed("send: \(String(cString: strerror(errno)))")
                }
            }
        }
    }

    /// Read one complete V5 frame. Reads the fixed 11-byte header first to learn
    /// the declared payload length, then reads the remainder.
    private func receiveV5Frame() throws -> [UInt8] {
        var buffer = [UInt8]()
        // Read at least the header (11 bytes) to determine total length.
        while buffer.count < 11 {
            let chunk = try readSome(maxLength: 11 - buffer.count)
            buffer.append(contentsOf: chunk)
        }
        guard buffer[0] == 0xA5 else {
            throw SolarmanError.v5Frame("unexpected start byte 0x\(String(buffer[0], radix: 16))")
        }
        let payloadLen = Int(buffer[1]) | (Int(buffer[2]) << 8)
        let totalLen = 13 + payloadLen  // header(11) + checksum(1) + end(1) + payload
        while buffer.count < totalLen {
            let chunk = try readSome(maxLength: totalLen - buffer.count)
            buffer.append(contentsOf: chunk)
        }
        return buffer
    }

    private func readSome(maxLength: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: maxLength)
        let n = buf.withUnsafeMutableBytes { raw -> Int in
            Foundation.recv(fd, raw.baseAddress, maxLength, 0)
        }
        if n > 0 {
            return Array(buf[0..<n])
        } else if n == 0 {
            throw SolarmanError.connectionFailed("peer closed connection")
        } else {
            if errno == EINTR { return [] }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw SolarmanError.timeout }
            throw SolarmanError.connectionFailed("recv: \(String(cString: strerror(errno)))")
        }
    }
}
