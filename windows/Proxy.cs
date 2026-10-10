using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

/// SOCKS5 + HTTP proxy on 127.0.0.1. Every outbound socket is pinned to the tunnel adapter with
/// IP_UNICAST_IF, so apps pointed at it reach the network only through the VPN. With no tunnel set,
/// every connect fails: nothing ever falls back to the default route.
sealed class Proxy
{
    public const int Port = 18964;

    readonly object gate = new();
    int ifIndex;
    string dnsServer = "1.1.1.1";
    readonly Dictionary<string, (IPAddress ip, DateTime expires)> cache = [];

    public void SetTunnel(int index, string? dns)
    {
        lock (gate) { ifIndex = index; dnsServer = dns ?? "1.1.1.1"; cache.Clear(); }
    }

    public void Start()
    {
        var listener = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp) { ExclusiveAddressUse = true };  // no other program may share the port
        listener.Bind(new IPEndPoint(IPAddress.Loopback, Port));
        listener.Listen(128);
        // ponytail: one blocking thread per connection. Fine for a few hundred; move to async sockets if it ever isn't.
        new Thread(() =>
        {
            while (true)
            {
                Socket c;
                try { c = listener.Accept(); } catch (SocketException) { Thread.Sleep(50); continue; }
                new Thread(() => Handle(c), 256 * 1024) { IsBackground = true }.Start();
            }
        }) { IsBackground = true }.Start();
    }

    void Handle(Socket c)
    {
        using var _ = c;
        try
        {
            if (ReadN(c, 1) is not [var first]) return;
            using var o = first == 5 ? Socks(c) : Http(c, first);
            if (o != null) Relay(c, o);
        }
        catch (Exception) { }  // one broken connection must not take the app down with its thread
    }

    Socket? Socks(Socket c)
    {
        Socket? Fail(byte code) { WriteAll(c, [5, code, 0, 1, 0, 0, 0, 0, 0, 0]); return null; }
        if (ReadN(c, 1) is not [var n] || ReadN(c, n) == null || !WriteAll(c, [5, 0]) || ReadN(c, 4) is not { } h) return null;
        if (h[1] != 1) return Fail(7);  // CONNECT only
        string host;
        switch (h[3])
        {
            case 1:
                if (ReadN(c, 4) is not { } a) return null;
                host = string.Join('.', a);
                break;
            case 3:
                if (ReadN(c, 1) is not [var len] || ReadN(c, len) is not { } name) return null;
                host = Encoding.UTF8.GetString(name);
                break;
            default:
                return Fail(8);  // ponytail: IPv4 tunnel only; IPv6 targets are refused, never sent direct
        }
        if (ReadN(c, 2) is not { } p) return null;
        if (ConnectOut(host, p[0] << 8 | p[1]) is not { } o) return Fail(4);
        if (!WriteAll(c, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])) { o.Dispose(); return null; }
        return o;
    }

    Socket? Http(Socket c, byte first)
    {
        Socket? Fail() { WriteAll(c, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"u8.ToArray()); return null; }
        // Byte-wise so the request body stays in the socket for Relay().
        var buf = new List<byte> { first };
        while (!(buf.Count >= 4 && buf[^4] == 13 && buf[^3] == 10 && buf[^2] == 13 && buf[^1] == 10))
        {
            if (buf.Count >= 65536 || ReadN(c, 1) is not [var b]) return null;
            buf.Add(b);
        }
        var lines = Encoding.Latin1.GetString(buf.ToArray()).Split("\r\n");
        var req = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (req.Length != 3) return Fail();

        if (req[0] == "CONNECT")
        {
            var hp = req[1].Split(':');
            if (hp.Length != 2 || !ushort.TryParse(hp[1], out var port) || ConnectOut(hp[0], port) is not { } tunnel) return Fail();
            if (!WriteAll(c, "HTTP/1.1 200 Connection established\r\n\r\n"u8.ToArray())) { tunnel.Dispose(); return null; }
            return tunnel;
        }
        // Plain http://: rewrite to origin-form and force one request per connection.
        if (!Uri.TryCreate(req[1], UriKind.Absolute, out var url) || url.Scheme != "http" || ConnectOut(url.Host, url.Port) is not { } o) return Fail();
        var head = new[] { $"{req[0]} {url.PathAndQuery} {req[2]}", "Connection: close" }
            .Concat(lines.Skip(1).Where(l => !l.StartsWith("connection:", StringComparison.OrdinalIgnoreCase) && !l.StartsWith("proxy-connection:", StringComparison.OrdinalIgnoreCase)));
        if (!WriteAll(o, Encoding.Latin1.GetBytes(string.Join("\r\n", head)))) { o.Dispose(); return null; }
        return o;
    }

    Socket? ConnectOut(string host, int port)
    {
        int idx; string dns;
        lock (gate) { idx = ifIndex; dns = dnsServer; }
        if (!IPAddress.TryParse(host, out var ip)) ip = Resolve(host.ToLowerInvariant(), dns, idx);
        if (ip?.AddressFamily != AddressFamily.InterNetwork || BoundSocket(SocketType.Stream, ProtocolType.Tcp, idx) is not { } s) return null;
        try
        {
            using var timeout = new CancellationTokenSource(15_000);
            s.ConnectAsync(new IPEndPoint(ip, port), timeout.Token).AsTask().GetAwaiter().GetResult();
            return s;
        }
        catch (Exception e) when (e is SocketException or OperationCanceledException) { s.Dispose(); return null; }
    }

    /// Never returns an unpinned socket: that would leak traffic outside the VPN.
    static Socket? BoundSocket(SocketType type, ProtocolType protocol, int idx)
    {
        if (idx == 0) return null;  // to Windows, index 0 means "route this normally"
        var s = new Socket(AddressFamily.InterNetwork, type, protocol);
        try
        {
            s.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31 /* IP_UNICAST_IF */, IPAddress.HostToNetworkOrder(idx));
            return s;
        }
        catch (SocketException) { s.Dispose(); return null; }  // the adapter is gone
    }

    /// DNS through the tunnel, so lookups for VPN apps don't go to the local resolver.
    /// ponytail: A records over UDP with a fixed 60s cache. Add AAAA / TCP fallback if the tunnel carries IPv6.
    IPAddress? Resolve(string host, string dns, int idx)
    {
        lock (gate) { if (cache.TryGetValue(host, out var hit) && hit.expires > DateTime.UtcNow) return hit.ip; }

        var q = new List<byte>(RandomNumberGenerator.GetBytes(2)) { 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
        foreach (var label in host.Split('.', StringSplitOptions.RemoveEmptyEntries))
        {
            var bytes = Encoding.UTF8.GetBytes(label);
            if (bytes.Length >= 64) return null;
            q.Add((byte)bytes.Length);
            q.AddRange(bytes);
        }
        q.AddRange([0, 0, 1, 0, 1]);

        if (!IPAddress.TryParse(dns, out var server) || BoundSocket(SocketType.Dgram, ProtocolType.Udp, idx) is not { } s) return null;
        using var _ = s;
        var r = new byte[1500];
        try
        {
            s.ReceiveTimeout = 3000;
            s.Connect(server, 53);
            for (int attempt = 0; attempt < 2; attempt++)
            {
                s.Send(q.ToArray());
                int n;
                try { n = s.Receive(r); } catch (SocketException e) when (e.SocketErrorCode == SocketError.TimedOut) { continue; }
                if (n < 12 || r[0] != q[0] || r[1] != q[1]) continue;  // stray packet: retry
                if (FirstA(r.AsSpan(0, n)) is not { } ip) return null;
                lock (gate) cache[host] = (ip, DateTime.UtcNow.AddSeconds(60));
                return ip;
            }
        }
        catch (SocketException) { }
        return null;
    }

    static IPAddress? FirstA(ReadOnlySpan<byte> r)
    {
        int i = 12;
        bool SkipName(ReadOnlySpan<byte> r)
        {
            while (i < r.Length)
            {
                int len = r[i];
                if (len == 0) { i += 1; return true; }
                if ((len & 0xC0) == 0xC0) { i += 2; return true; }
                i += 1 + len;
            }
            return false;
        }
        int questions = r[4] << 8 | r[5], answers = r[6] << 8 | r[7];
        for (int k = 0; k < questions; k++)
        {
            if (!SkipName(r)) return null;
            i += 4;
        }
        for (int k = 0; k < answers; k++)
        {
            if (!SkipName(r) || i + 10 > r.Length) return null;
            int type = r[i] << 8 | r[i + 1], len = r[i + 8] << 8 | r[i + 9];
            i += 10;
            if (i + len > r.Length) return null;
            if (type == 1 && len == 4) return new IPAddress(r.Slice(i, 4));
            i += len;
        }
        return null;
    }

    static void Relay(Socket a, Socket b)
    {
        var buf = new byte[65536];
        var open = new List<Socket> { a, b };
        while (open.Count > 0)
        {
            var ready = new List<Socket>(open);
            try { Socket.Select(ready, null, null, -1); } catch (Exception e) when (e is SocketException or ObjectDisposedException) { return; }
            foreach (var from in ready)
            {
                var to = from == a ? b : a;
                int n;
                try { n = from.Receive(buf); } catch (SocketException) { n = 0; }
                if (n > 0)
                {
                    if (!WriteAll(to, buf.AsSpan(0, n))) return;
                }
                else
                {
                    try { to.Shutdown(SocketShutdown.Send); } catch (SocketException) { }
                    open.Remove(from);
                }
            }
        }
    }

    static byte[]? ReadN(Socket s, int n)
    {
        var buf = new byte[n];
        for (int off = 0; off < n;)
        {
            int r;
            try { r = s.Receive(buf, off, n - off, SocketFlags.None); } catch (SocketException) { return null; }
            if (r <= 0) return null;
            off += r;
        }
        return buf;
    }

    static bool WriteAll(Socket s, ReadOnlySpan<byte> bytes)
    {
        try
        {
            while (bytes.Length > 0) bytes = bytes[s.Send(bytes)..];
            return true;
        }
        catch (SocketException) { return false; }
    }

    /// `AppVPN --selftest <interface index>`: runs the proxy pinned to a real adapter and checks each path with curl.
    public static int SelfTest(int index)
    {
        var proxy = new Proxy();
        try { proxy.Start(); } catch (SocketException e) { Console.WriteLine($"FAIL listen: {e.Message}"); return 1; }
        var addr = $"127.0.0.1:{Port}";
        bool failed = false;
        void Check(string name, bool expect, params string[] args)
        {
            using var p = Process.Start(new ProcessStartInfo("curl.exe", ["-s", "-m", "10", "-o", "NUL", .. args]) { CreateNoWindow = true })!;
            p.WaitForExit();
            bool ok = (p.ExitCode == 0) == expect;
            failed |= !ok;
            Console.WriteLine($"{(ok ? "ok  " : "FAIL")} {name}");
        }
        Check("no tunnel: connection refused, not sent direct", false, "-x", $"socks5h://{addr}", "https://example.com");
        proxy.SetTunnel(index, null);
        Check("socks5 by hostname", true, "-x", $"socks5h://{addr}", "https://example.com");
        Check("socks5 by IPv4", true, "-x", $"socks5://{addr}", "https://1.1.1.1");
        Check("http CONNECT", true, "-x", $"http://{addr}", "https://example.com");
        Check("plain http", true, "-f", "-x", $"http://{addr}", "http://example.com/?a=1");
        Check("unknown host fails", false, "-x", $"socks5h://{addr}", "https://nope.invalid");
        proxy.SetTunnel(9999, null);
        Check("missing interface: fails closed", false, "-x", $"socks5h://{addr}", "https://example.com");
        return failed ? 1 : 0;
    }
}
