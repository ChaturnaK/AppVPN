import Foundation

/// SOCKS5 + HTTP proxy on 127.0.0.1. Every outbound socket is pinned to the tunnel interface with
/// IP_BOUND_IF, so apps pointed at it reach the network only through the VPN. With no tunnel set,
/// every connect fails: nothing ever falls back to the default route.
final class Proxy {
    static let port: UInt16 = 18964
    /// For `sandbox-exec`: a program started under it reaches this proxy and nothing else, not even the local resolver.
    /// ponytail: sandbox-exec is deprecated and a process takes one sandbox only, so apps that apply their own
    /// (Chromium, Electron, App Sandbox) cannot start under it. The supported way is a Network Extension content filter.
    static let sandbox = "(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip \"localhost:\(port)\"))"

    private let lock = NSLock()
    private var ifIndex: UInt32 = 0
    private var dnsServer = "1.1.1.1"
    private var cache: [String: (ip: in_addr, expires: Date)] = [:]

    func setTunnel(ifName: String?, dns: String?) {
        lock.lock(); defer { lock.unlock() }
        ifIndex = ifName.map { if_nametoindex($0) } ?? 0
        dnsServer = dns ?? "1.1.1.1"
        cache.removeAll()
    }

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        // GUI apps start with 256 fds; a browser alone opens more connections than that.
        var lim = rlimit(rlim_cur: 8192, rlim_max: 8192)
        setrlimit(RLIMIT_NOFILE, &lim)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, 4)
        let loopback = sockaddr4(in_addr(s_addr: inet_addr("127.0.0.1")), Self.port)
        guard withSockaddr(loopback, { bind(fd, $0, $1) }) == 0, listen(fd, 128) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        // ponytail: one blocking thread per connection. Fine for a few hundred; move to kqueue if it ever isn't.
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { usleep(50_000); continue }
                Thread.detachNewThread { self.handle(c) }
            }
        }
    }

    private func handle(_ c: Int32) {
        defer { close(c) }
        var on: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, 4)
        guard let first = readN(c, 1), let out = first[0] == 5 ? socks(c) : http(c, first[0]) else { return }
        relay(c, out)
        close(out)
    }

    private func socks(_ c: Int32) -> Int32? {
        func fail(_ code: UInt8) -> Int32? { _ = writeAll(c, [5, code, 0, 1, 0, 0, 0, 0, 0, 0]); return nil }
        guard let n = readN(c, 1), readN(c, Int(n[0])) != nil, writeAll(c, [5, 0]), let h = readN(c, 4) else { return nil }
        guard h[1] == 1 else { return fail(7) }  // CONNECT only
        let host: String
        switch h[3] {
        case 1:
            guard let a = readN(c, 4) else { return nil }
            host = a.map(String.init).joined(separator: ".")
        case 3:
            guard let l = readN(c, 1), let a = readN(c, Int(l[0])), let s = String(bytes: a, encoding: .utf8) else { return nil }
            host = s
        default:
            return fail(8)  // ponytail: IPv4 tunnel only; IPv6 targets are refused, never sent direct
        }
        guard let p = readN(c, 2) else { return nil }
        guard let out = connectOut(host, UInt16(p[0]) << 8 | UInt16(p[1])) else { return fail(4) }
        guard writeAll(c, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]) else { close(out); return nil }
        return out
    }

    private func http(_ c: Int32, _ first: UInt8) -> Int32? {
        func fail() -> Int32? { _ = writeAll(c, Array("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8)); return nil }
        // Byte-wise so the request body stays in the socket for relay().
        var buf = [first]
        while !buf.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard buf.count < 65536, let b = readN(c, 1) else { return nil }
            buf += b
        }
        var lines = String(bytes: buf, encoding: .isoLatin1)!.components(separatedBy: "\r\n")
        let req = lines[0].split(separator: " ")
        guard req.count == 3 else { return fail() }

        if req[0] == "CONNECT" {
            let hp = req[1].split(separator: ":")
            guard hp.count == 2, let port = UInt16(hp[1]), let out = connectOut(String(hp[0]), port) else { return fail() }
            guard writeAll(c, Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8)) else { close(out); return nil }
            return out
        }
        // Plain http://: rewrite to origin-form and force one request per connection.
        guard let url = URLComponents(string: String(req[1])), url.scheme == "http", let host = url.host,
              let out = connectOut(host, UInt16(url.port ?? 80)) else { return fail() }
        let path = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath) + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        lines = ["\(req[0]) \(path) \(req[2])", "Connection: close"] + lines.dropFirst().filter {
            let l = $0.lowercased()
            return !l.hasPrefix("connection:") && !l.hasPrefix("proxy-connection:")
        }
        guard writeAll(out, Array(lines.joined(separator: "\r\n").data(using: .isoLatin1)!)) else { close(out); return nil }
        return out
    }

    private func connectOut(_ host: String, _ port: UInt16) -> Int32? {
        lock.lock(); let idx = ifIndex, dns = dnsServer; lock.unlock()
        var ip = in_addr()
        if inet_pton(AF_INET, host, &ip) != 1 {
            guard let r = resolve(host.lowercased(), dns, idx) else { return nil }
            ip = r
        }
        guard let fd = boundSocket(SOCK_STREAM, idx) else { return nil }
        var timeout: Int32 = 15
        setsockopt(fd, IPPROTO_TCP, TCP_CONNECTIONTIMEOUT, &timeout, 4)
        guard withSockaddr(sockaddr4(ip, port), { connect(fd, $0, $1) }) == 0 else { close(fd); return nil }
        return fd
    }

    /// Never returns an unpinned socket: that would leak traffic outside the VPN.
    private func boundSocket(_ type: Int32, _ idx: UInt32) -> Int32? {
        guard idx != 0 else { return nil }
        let fd = socket(AF_INET, type, 0)
        var i = idx, on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, 4)
        guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &i, 4) == 0 else { close(fd); return nil }
        return fd
    }

    /// DNS through the tunnel, so lookups for VPN apps don't go to the local resolver.
    /// ponytail: A records over UDP with a fixed 60s cache. Add AAAA / TCP fallback if the tunnel carries IPv6.
    private func resolve(_ host: String, _ dns: String, _ idx: UInt32) -> in_addr? {
        lock.lock(); let hit = cache[host]; lock.unlock()
        if let hit, hit.expires > Date() { return hit.ip }

        var q: [UInt8] = [.random(in: 0...255), .random(in: 0...255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in host.split(separator: ".") {
            guard label.utf8.count < 64 else { return nil }
            q.append(UInt8(label.utf8.count))
            q += label.utf8
        }
        q += [0, 0, 1, 0, 1]

        var server = in_addr()
        guard inet_pton(AF_INET, dns, &server) == 1, let fd = boundSocket(SOCK_DGRAM, idx) else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard withSockaddr(sockaddr4(server, 53), { connect(fd, $0, $1) }) == 0 else { return nil }

        var r = [UInt8](repeating: 0, count: 1500)
        for _ in 0..<2 {
            guard send(fd, q, q.count, 0) == q.count else { return nil }
            let n = recv(fd, &r, r.count, 0)
            guard n >= 12, r[0] == q[0], r[1] == q[1] else { continue }  // timeout or stray packet: retry
            guard let ip = firstA(Array(r[..<n])) else { return nil }
            lock.lock(); cache[host] = (ip, Date().addingTimeInterval(60)); lock.unlock()
            return ip
        }
        return nil
    }

    private func firstA(_ r: [UInt8]) -> in_addr? {
        var i = 12
        func skipName() -> Bool {
            while i < r.count {
                let len = Int(r[i])
                if len == 0 { i += 1; return true }
                if len & 0xC0 == 0xC0 { i += 2; return true }
                i += 1 + len
            }
            return false
        }
        let questions = Int(r[4]) << 8 | Int(r[5]), answers = Int(r[6]) << 8 | Int(r[7])
        for _ in 0..<questions {
            guard skipName() else { return nil }
            i += 4
        }
        for _ in 0..<answers {
            guard skipName(), i + 10 <= r.count else { return nil }
            let type = Int(r[i]) << 8 | Int(r[i + 1]), len = Int(r[i + 8]) << 8 | Int(r[i + 9])
            i += 10
            guard i + len <= r.count else { return nil }
            if type == 1, len == 4 {
                return in_addr(s_addr: r[i..<i + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            }
            i += len
        }
        return nil
    }

    private func relay(_ a: Int32, _ b: Int32) {
        var fds = [pollfd(fd: a, events: Int16(POLLIN), revents: 0), pollfd(fd: b, events: Int16(POLLIN), revents: 0)]
        var buf = [UInt8](repeating: 0, count: 65536)
        var open = 2
        while open > 0, poll(&fds, 2, -1) > 0 {
            for i in 0..<2 where fds[i].revents != 0 {
                let other = i == 0 ? b : a
                let n = read(fds[i].fd, &buf, buf.count)
                if n > 0 {
                    guard writeAll(other, Array(buf[..<n])) else { return }
                } else {
                    shutdown(other, SHUT_WR)
                    fds[i].fd = -1  // poll ignores negative fds
                    open -= 1
                }
            }
        }
    }

    private func readN(_ fd: Int32, _ n: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n), off = 0
        while off < n {
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + off, n - off) }
            if r <= 0 { return nil }
            off += r
        }
        return buf
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + off, bytes.count - off) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    private func sockaddr4(_ ip: in_addr, _ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr = ip
        return a
    }

    private func withSockaddr<T>(_ a: sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var a = a
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
}

/// `AppVPN --selftest en0`: runs the proxy pinned to a real interface and checks each path with curl.
func selfTest(interface: String) -> Int32 {
    let proxy = Proxy()
    do { try proxy.start() } catch { print("FAIL listen: \(error)"); return 1 }
    let addr = "127.0.0.1:\(Proxy.port)"
    var failed = false
    func check(_ name: String, expect: Bool, sandboxed: Bool = false, _ args: String...) {
        let p = Process(), curl = ["/usr/bin/curl", "-s", "-m", "10", "-o", "/dev/null"] + args
        p.executableURL = URL(fileURLWithPath: sandboxed ? "/usr/bin/sandbox-exec" : curl[0])
        p.arguments = sandboxed ? ["-p", Proxy.sandbox] + curl : Array(curl.dropFirst())
        try? p.run()
        p.waitUntilExit()
        let ok = (p.terminationStatus == 0) == expect
        failed = failed || !ok
        print("\(ok ? "ok  " : "FAIL") \(name)")
    }
    check("no tunnel: connection refused, not sent direct", expect: false, "-x", "socks5h://\(addr)", "https://example.com")
    proxy.setTunnel(ifName: interface, dns: nil)
    check("socks5 by hostname", expect: true, "-x", "socks5h://\(addr)", "https://example.com")
    check("socks5 by IPv4", expect: true, "-x", "socks5://\(addr)", "https://1.1.1.1")
    check("http CONNECT", expect: true, "-x", "http://\(addr)", "https://example.com")
    check("plain http", expect: true, "-f", "-x", "http://\(addr)", "http://example.com/?a=1")
    check("unknown host fails", expect: false, "-x", "socks5h://\(addr)", "https://nope.invalid")
    check("sandboxed: reaches the proxy", expect: true, sandboxed: true, "-x", "socks5h://\(addr)", "https://example.com")
    check("sandboxed: direct connection blocked", expect: false, sandboxed: true, "https://1.1.1.1")
    check("sandboxed: local DNS blocked", expect: false, sandboxed: true, "https://example.com")
    proxy.setTunnel(ifName: "nosuchif0", dns: nil)
    check("missing interface: fails closed", expect: false, "-x", "socks5h://\(addr)", "https://example.com")
    return failed ? 1 : 0
}
