import Foundation

/// Result of a successful logger discovery.
struct DiscoveryResult {
    let ip: String
    let mac: String?      // present only for the broadcast path
    let method: String    // "broadcast" or "tcp-sweep"
}

/// Finds the Solarman logger on the LAN after its IP changes (the logger's DHCP
/// lease is not stable). Two strategies, tried in order:
///   1. Solarman UDP broadcast on :48899 — instant, and works even while the GUI
///      holds the logger's single TCP socket.
///   2. TCP sweep of the local /24 on :8899, verifying each hit with a real V5
///      handshake for OUR logger serial — only our logger passes.
/// All blocking; call from a background queue. Read-only: the V5 probe issues a
/// Modbus func 0x03 read, never a write.
enum LoggerDiscovery {

    static func discover(loggerMAC: String, serial: UInt32, slave: UInt8) -> DiscoveryResult? {
        guard let prefix = localSubnetPrefix() else { return nil }
        if let r = broadcast(loggerMAC: loggerMAC, serial: serial, prefix: prefix) { return r }
        return tcpSweep(prefix: prefix, serial: serial, slave: slave)
    }

    // MARK: - Local subnet

    /// The /24 prefix ("192.168.1.") of the Mac's primary IPv4 — first up,
    /// non-loopback `en` interface (getifaddrs).
    static func localSubnetPrefix() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var ptr = ifap
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard String(cString: p.pointee.ifa_name).hasPrefix("en") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if let dot = ip.range(of: ".", options: .backwards) {
                return String(ip[..<dot.upperBound])   // "192.168.1."
            }
        }
        return nil
    }

    // MARK: - Broadcast

    /// Send the Solarman discovery beacon and match a reply to our logger by MAC
    /// (or by serial, if the reply carries it) — matching either identifier.
    static func broadcast(loggerMAC: String, serial: UInt32, prefix: String,
                          timeout: TimeInterval = 2.0) -> DiscoveryResult? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { Foundation.close(fd) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(48899).bigEndian
        inet_pton(AF_INET, prefix + "255", &addr.sin_addr)

        let msg = Array("WIFIKIT-214028-READ".utf8)
        let sent = msg.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, msg.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return nil }

        let wantMAC = normalizeMAC(loggerMAC)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var buf = [UInt8](repeating: 0, count: 256)
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }   // timeout/error
            guard let s = String(bytes: buf[0..<n], encoding: .utf8) else { continue }
            // Reply looks like "IP,MAC,SERIAL" (comma separated).
            let parts = s.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count >= 2 else { continue }
            let ip = parts[0]
            let mac = parts[1]
            let macMatch = normalizeMAC(mac) == wantMAC
            let serialMatch = parts.count >= 3 && UInt32(parts[2]) == serial
            if macMatch || serialMatch {
                return DiscoveryResult(ip: ip, mac: mac, method: "broadcast")
            }
        }
        return nil
    }

    // MARK: - TCP sweep

    /// Probe every host in the /24 on :8899 concurrently (cap 64 in-flight) and
    /// accept the first that completes a valid V5 handshake for OUR serial.
    static func tcpSweep(prefix: String, serial: UInt32, slave: UInt8, port: UInt16 = 8899) -> DiscoveryResult? {
        let sem = DispatchSemaphore(value: 64)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.deyewidget.sweep", attributes: .concurrent)
        let lock = NSLock()
        var found: DiscoveryResult?

        func result() -> DiscoveryResult? { lock.lock(); defer { lock.unlock() }; return found }

        for h in 1...254 {
            if result() != nil { break }
            let ip = "\(prefix)\(h)"
            sem.wait()
            group.enter()
            queue.async {
                defer { sem.signal(); group.leave() }
                if result() != nil { return }
                // 1 s connect+read timeout: dead hosts fail on connect, open-but-
                // wrong ports fail the V5 decode (serial echo won't match).
                let c = SolarmanClient(host: ip, port: port, loggerSerial: serial, slaveId: slave, timeout: 1.0)
                defer { c.close() }
                if (try? c.readHoldingRegisters(start: 150, quantity: 1)) != nil {
                    lock.lock()
                    if found == nil { found = DiscoveryResult(ip: ip, mac: nil, method: "tcp-sweep") }
                    lock.unlock()
                }
            }
        }
        group.wait()
        return found
    }

    // MARK: - Helpers

    /// Uppercase, strip separators — compare MACs regardless of ':'/'-'/spacing.
    static func normalizeMAC(_ mac: String) -> String {
        mac.uppercased().filter { $0.isHexDigit }
    }
}
