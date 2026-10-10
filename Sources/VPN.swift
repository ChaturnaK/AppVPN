import AppKit
import Foundation

/// Runs open-source OpenVPN as root with no system routes, and tracks it over its management socket.
/// ponytail: certificate-only profiles. For auth-user-pass or key passphrases, add
/// --management-query-passwords and answer the >PASSWORD: prompts here.
@MainActor
final class VPN: ObservableObject {
    @Published var state = "DISCONNECTED"
    @Published var detail = ""
    @Published var busy = false

    let proxy = Proxy()
    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".appvpn")
    private var mgmt: FileHandle?
    private var dns: String?
    private var wantDown = false

    var connected: Bool { state == "CONNECTED" }
    private var logPath: String { dir.appendingPathComponent("openvpn.log").path }
    private var logShown: String { (logPath as NSString).abbreviatingWithTildeInPath }

    init() {
        do { try proxy.start() } catch { detail = "Proxy port \(Proxy.port) unavailable: \(error.localizedDescription)" }
        attach()  // pick up a tunnel left running by a previous launch
        // ponytail: only wake is handled. A Wi-Fi/network switch without sleep is noticed by ping-restart within 60 s; for instant recovery add an NWPathMonitor on physical interfaces (ignore utun, debounce) that sends the same signal.
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mgmt != nil, self.state != "DISCONNECTED" else { return }
                try? self.mgmt?.write(contentsOf: Data("signal SIGUSR1\n".utf8))
            }
        }
    }

    func connect(profile: String) {
        guard let script = Bundle.main.path(forResource: "vpn", ofType: "sh") else { detail = "vpn.sh missing from app bundle"; return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logPath, contents: nil)  // user-owned and empty, so we can read what root appends
        let cmd = [script, "start", profile, dir.path, NSUserName()]
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        busy = true
        detail = ""
        dns = nil  // the last profile's server must not answer for this one
        Task.detached {
            let p = Process(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
            p.standardError = err
            try? p.run()
            p.waitUntilExit()
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            await MainActor.run {
                if p.terminationStatus == 0 { self.attach(retries: 20) } else { self.busy = false; self.detail = msg }
            }
        }
    }

    func disconnect() {
        wantDown = true
        try? mgmt?.write(contentsOf: Data("signal SIGTERM\n".utf8))
    }

    private func attach(retries: Int = 0) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = dir.appendingPathComponent("mgmt.sock").path
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else {
            close(fd)
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.attach(retries: retries - 1) }
            } else if busy {
                busy = false
                detail = "OpenVPN did not start. " + logTail()
            }
            return
        }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        mgmt = h
        busy = false
        // --management-hold re-arms on every restart (ping-restart, SIGUSR1); without `hold off` the first automatic reconnect would wait for a release forever.
        try? h.write(contentsOf: Data("state on\nstate\nlog on all\nhold off\nhold release\n".utf8))
        Task {
            do { for try await l in h.bytes.lines { self.line(l) } } catch {}
            self.mgmt = nil
            if self.connected { self.detail = "OpenVPN stopped unexpectedly. Log: \(self.logShown)" }  // killed: no EXITING seen
            self.proxy.setTunnel(ifName: nil, dns: nil)
            self.state = "DISCONNECTED"
            self.wantDown = false
        }
    }

    private func line(_ l: String) {
        // The pushed DNS server is only visible in the logged PUSH_REPLY, since --route-nopull drops it.
        if let m = l.firstMatch(of: #/(?:dhcp-option DNS|dns server \d+ address) (\d+\.\d+\.\d+\.\d+)/#) { dns = String(m.1) }
        if l.hasPrefix(">FATAL:") { detail = String(l.dropFirst(7)) }

        // State lines: "<unix time>,<STATE>,<description>,<tunnel ip>,..." (">STATE:" prefix when real-time).
        let f = l.replacingOccurrences(of: ">STATE:", with: "").split(separator: ",", omittingEmptySubsequences: false)
        guard f.count >= 4, Int(f[0]) != nil, f[1].count > 3, f[1].allSatisfy({ $0.isUppercase || $0 == "_" }) else { return }
        let wasConnected = connected
        state = String(f[1])
        if connected {
            let ip = String(f[3]), ifName = interfaceName(for: ip)
            proxy.setTunnel(ifName: ifName, dns: dns)
            detail = ifName.map { "\(ip) on \($0)" } ?? "Connected, but no interface has \(ip)"
        } else {
            proxy.setTunnel(ifName: nil, dns: nil)
            if wasConnected { detail = "" }  // it held the tunnel address
            if state == "EXITING", !wantDown {
                let why = f[2] == "auth-failure"
                    ? "The server rejected this profile's login (AUTH_FAILED). The account may have expired."
                    : "OpenVPN exited: \(f[2])."
                detail = "\(why) Log: \(logShown)"
            }
        }
    }

    private func logTail() -> String {
        let lines = (try? String(contentsOfFile: logPath, encoding: .utf8))?.split(separator: "\n") ?? []
        return lines.suffix(3).joined(separator: "\n")
    }

    private func interfaceName(for ip: String) -> String? {
        var want = in_addr(), list: UnsafeMutablePointer<ifaddrs>?
        guard inet_pton(AF_INET, ip, &want) == 1, getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var p = list
        while let i = p {
            if let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee.sin_addr.s_addr }) == want.s_addr {
                return String(cString: i.pointee.ifa_name)
            }
            p = i.pointee.ifa_next
        }
        return nil
    }
}
