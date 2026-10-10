using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

/// Runs the installed OpenVPN as administrator with no system routes or DNS, and tracks it over its management interface.
/// ponytail: certificate-only profiles. For auth-user-pass or key passphrases, add
/// --management-query-passwords and answer the >PASSWORD: prompts here.
/// ponytail: OpenVPN's arguments and the profile come from this unelevated app, and Windows asks for approval on
/// every connect. Upgrade path: a Windows service that owns the profile check and the start.
sealed class Vpn
{
    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AppVPN");
    const int ManagementPort = 18965;
    static string LogPath => Path.Combine(Dir, "openvpn.log");
    static string PasswordPath => Path.Combine(Dir, "mgmt.pw");
    static readonly Regex PushedDns = new(@"(?:dhcp-option DNS|dns server [0-9]+ address) ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)");

    public event Action? Changed;
    public string State { get; private set; } = "DISCONNECTED";
    public string Detail { get; private set; } = "";
    public bool Busy { get; private set; }
    public bool Connected => State == "CONNECTED";
    public readonly Proxy Proxy = new();

    Stream? mgmt;
    string? dns;
    bool wantDown;
    int startedPid;

    public Vpn()
    {
        try { Proxy.Start(); } catch (SocketException e) { Detail = $"Proxy port {Proxy.Port} unavailable: {e.Message}"; }
        _ = Attach();  // pick up a tunnel left running by a previous launch
        // ponytail: only wake is handled. A Wi-Fi/network switch without sleep is noticed by ping-restart within 60 s; for instant recovery watch NetworkChange.NetworkAddressChanged on physical adapters (debounced) and send the same signal.
        var ui = SynchronizationContext.Current!;
        SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode == PowerModes.Resume) ui.Post(_ => { if (State != "DISCONNECTED") Send("signal SIGUSR1\n"); }, null);
        };
    }

    /// OpenVPN as its installer registered it. Only administrators can change that key or the folder it names.
    public static string? OpenVpnExe()
    {
        using var key = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64).OpenSubKey(@"SOFTWARE\OpenVPN");
        var exe = key?.GetValue("exe_path") as string ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"OpenVPN\bin\openvpn.exe");
        return File.Exists(exe) ? exe : null;
    }

    public async void Connect(string profile)
    {
        void Fail(string why) { Busy = false; Detail = why; Changed?.Invoke(); }
        if (OpenVpnExe() is not { } exe) { Fail("OpenVPN is not installed. Run the AppVPN setup program again, or install OpenVPN 2.7 from openvpn.net."); return; }
        string[] args;
        try
        {
            var bytes = File.ReadAllBytes(profile);
            if (Allowlist.Check(bytes) is { } bad) { Fail(Allowlist.Message(bad)); return; }
            Directory.CreateDirectory(Dir);
            File.WriteAllText(LogPath, "");  // ours and empty, so we can read what OpenVPN appends
            File.WriteAllText(PasswordPath, Convert.ToHexString(RandomNumberGenerator.GetBytes(16)) + "\n");

            var words = ProfileStore.Words(Encoding.Latin1.GetString(bytes)).Select(w => w[0].StartsWith("--", StringComparison.Ordinal) ? [w[0][2..], .. w[1..]] : w).ToList();
            // Old servers without cipher negotiation need the profile's cipher as fallback on OpenVPN 2.6+.
            var cipher = words.FirstOrDefault(w => w is ["cipher", _, ..])?[1];
            // Dead-peer detection, only if the profile sets none: OpenVPN refuses --ping next to a profile's keepalive.
            bool ownPing = words.Any(w => w[0] is "keepalive" or "ping" or "ping-restart" or "ping-exit");
            args =
            [
                // ip-win32 and route-method are the two pushed settings --route-nopull lets through that change how the adapter is set up.
                // Before --config, so a pull-filter line in the profile cannot accept them first.
                "--pull-filter", "ignore", "ip-win32", "--pull-filter", "ignore", "route-method",
                "--cd", Path.GetDirectoryName(profile)!, "--config", profile,
                // --route-nopull: accept the tunnel address but none of the pushed routes, DNS servers or DNS blocking.
                // (Those written in the profile were removed at import; Allowlist.Check has just made sure.)
                // --route: Windows has no routes scoped to one adapter, so the tunnel gets a default route that loses to
                // every real one. Only sockets pinned to the tunnel adapter (the app's proxy) use it.
                "--route-nopull", "--route", "0.0.0.0", "0.0.0.0", "vpn_gateway", "9000",
                // --persist-tun: keep the tunnel adapter up across automatic restarts.
                // --connect-retry / --resolv-retry: retry forever after a lost connection, 2 s apart, slowing to 30 s after repeated failures.
                "--persist-tun", "--connect-retry", "2", "30", "--resolv-retry", "infinite", .. ownPing ? (string[])[] : ["--ping", "10", "--ping-restart", "60"],
                // --management-hold: wait for the app to attach, so it sees every state change and error.
                "--management", "127.0.0.1", $"{ManagementPort}", PasswordPath, "--management-hold",
                "--log-append", LogPath, "--verb", "3", .. cipher == null ? (string[])[] : ["--data-ciphers-fallback", cipher],
            ];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Fail(e.Message); return; }

        Busy = true;
        Detail = "";
        dns = null;  // the last profile's server must not answer for this one
        Changed?.Invoke();
        try
        {
            startedPid = await Task.Run(() =>
            {
                using var p = Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden });
                return p?.Id ?? 0;
            });
        }
        catch (Win32Exception e) { Fail(e.NativeErrorCode == 1223 ? "Administrator approval was cancelled." : "Couldn't start OpenVPN: " + e.Message); return; }
        await Attach(retries: 40);
    }

    public void Disconnect()
    {
        wantDown = true;
        Send("signal SIGTERM\n");
    }

    void Send(string commands)
    {
        try { mgmt?.Write(Encoding.ASCII.GetBytes(commands)); } catch (IOException) { }
    }

    async Task Attach(int retries = 0)
    {
        TcpClient client;
        for (; ; retries--)
        {
            client = new TcpClient();
            try
            {
                if (ListenerIsOpenVpn()) { await client.ConnectAsync(IPAddress.Loopback, ManagementPort); break; }
            }
            catch (SocketException) { }
            client.Dispose();
            if (retries <= 0)
            {
                if (Busy) { Busy = false; Detail = "OpenVPN did not start. " + LogTail(); Changed?.Invoke(); }
                return;
            }
            await Task.Delay(250);
        }
        using var _ = client;
        mgmt = client.GetStream();
        Busy = false;
        string password = "";
        try { password = File.ReadAllText(PasswordPath).Trim(); } catch (IOException) { }
        // --management-hold re-arms on every restart (ping-restart, SIGUSR1); without `hold off` the first automatic reconnect would wait for a release forever.
        Send($"{password}\nstate on\nstate\nlog on all\nhold off\nhold release\n");
        Changed?.Invoke();
        try
        {
            using var reader = new StreamReader(mgmt, Encoding.Latin1);
            while (await reader.ReadLineAsync() is { } l) Line(l);
        }
        catch (IOException) { }
        mgmt = null;
        if (Connected) Detail = $"OpenVPN stopped unexpectedly. Log: {LogPath}";  // killed: no EXITING seen
        Proxy.SetTunnel(0, null);
        State = "DISCONNECTED";
        wantDown = false;
        Changed?.Invoke();
    }

    void Line(string l)
    {
        // The pushed DNS server is only visible in the logged PUSH_REPLY, since --route-nopull drops it.
        if (PushedDns.Match(l) is { Success: true } m) dns = m.Groups[1].Value;
        if (l.StartsWith(">FATAL:", StringComparison.Ordinal)) { Detail = l[7..]; Changed?.Invoke(); }

        // State lines: "<unix time>,<STATE>,<description>,<tunnel ip>,..." (">STATE:" prefix when real-time).
        var f = l.Replace(">STATE:", "").Split(',');
        if (f.Length < 4 || !long.TryParse(f[0], out _) || f[1].Length <= 3 || !f[1].All(c => c is >= 'A' and <= 'Z' or '_')) return;
        bool wasConnected = Connected;
        State = f[1];
        if (Connected)
        {
            var (index, name) = TunnelAdapter(f[3]);
            Proxy.SetTunnel(index, dns);
            Detail = index != 0 ? $"{f[3]} on {name}" : $"Connected, but no OpenVPN adapter has {f[3]}";
        }
        else
        {
            Proxy.SetTunnel(0, null);
            if (wasConnected) Detail = "";  // it held the tunnel address
            if (State == "EXITING" && !wantDown)
            {
                var why = f[2] == "auth-failure"
                    ? "The server rejected this profile's login (AUTH_FAILED). The account may have expired."
                    : $"OpenVPN exited: {f[2]}.";
                Detail = $"{why} Log: {LogPath}";
            }
        }
        Changed?.Invoke();
    }

    static string LogTail()
    {
        try
        {
            using var log = new StreamReader(new FileStream(LogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite));
            return string.Join('\n', log.ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries).TakeLast(3));
        }
        catch (IOException) { return ""; }
    }

    /// The adapter that holds the tunnel address, and only if it is one of OpenVPN's: whatever the management
    /// interface says, the proxy is never pinned to an ordinary network adapter.
    static (int index, string name) TunnelAdapter(string ip)
    {
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (!nic.Description.StartsWith("OpenVPN Data Channel Offload", StringComparison.Ordinal) && !nic.Description.StartsWith("TAP-Windows Adapter", StringComparison.Ordinal)) continue;
            var properties = nic.GetIPProperties();
            if (properties.UnicastAddresses.Any(a => a.Address.ToString() == ip)) return (properties.GetIPv4Properties().Index, nic.Name);
        }
        return (0, "");
    }

    /// On macOS the management socket sits in a folder only the user can open. A TCP port can be taken by any
    /// program on the PC, which could then report "connected" as it pleased. So the app talks to the port only
    /// while every listener on it is the installed OpenVPN.
    bool ListenerIsOpenVpn()
    {
        int size = 0;
        GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2 /* AF_INET */, 3 /* TCP_TABLE_OWNER_PID_LISTENER */, 0);
        var table = Marshal.AllocHGlobal(size);
        try
        {
            if (GetExtendedTcpTable(table, ref size, false, 2, 3, 0) != 0) return false;
            bool found = false;
            for (int i = 0, rows = Marshal.ReadInt32(table); i < rows; i++)
            {
                var row = table + 4 + i * 24;  // MIB_TCPROW_OWNER_PID: state, local address, local port, remote address, remote port, process id
                if ((Marshal.ReadByte(row, 8) << 8 | Marshal.ReadByte(row, 9)) != ManagementPort) continue;
                if (!IsOpenVpn(Marshal.ReadInt32(row, 20))) return false;
                found = true;
            }
            return found;
        }
        finally { Marshal.FreeHGlobal(table); }
    }

    bool IsOpenVpn(int pid)
    {
        var process = OpenProcess(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */, false, pid);
        // Not ours to look at: it runs under another administrator's account. Then only the one this app started counts.
        if (process == IntPtr.Zero) return startedPid != 0 && pid == startedPid;
        try
        {
            var path = new StringBuilder(1024);
            int length = path.Capacity;
            return QueryFullProcessImageName(process, 0, path, ref length) && string.Equals(path.ToString(), OpenVpnExe(), StringComparison.OrdinalIgnoreCase);
        }
        finally { CloseHandle(process); }
    }

    [DllImport("iphlpapi.dll")] static extern int GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int family, int tableClass, int reserved);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder path, ref int size);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
}
