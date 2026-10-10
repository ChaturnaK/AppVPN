using System.IO;
using System.Text;
using System.Text.RegularExpressions;

/// The profile check of vpn.sh ("check"), rule for rule, for Windows where there is no awk.
/// The profile is an untrusted download and OpenVPN runs as administrator, so this is an allowlist: only
/// ordinary client settings pass. Anything that runs code, loads a library, reads or writes other files,
/// or is simply unknown is refused.
/// Whatever this does not see, OpenVPN may still run, so it must split words and find block ends exactly
/// as OpenVPN does. Rather than copy OpenVPN's quoting rules, profiles where the two could differ are refused.
/// ponytail: a profile that quotes an argument (verify-x509-name "C=US, O=x") is refused.
/// Upgrade path: a tokeniser that implements OpenVPN's parse_line quoting rules.
static class Allowlist
{
    /// Routing and DNS settings. On macOS they are allowed because OpenVPN is told not to apply them. Windows
    /// has no switch for the ones written in the profile (block-outside-dns would block DNS for the whole PC),
    /// so import removes these lines and the check before connecting refuses them.
    static readonly HashSet<string> Removed = [.. "route route-ipv6 redirect-gateway redirect-private dhcp-option dns block-outside-dns block-ipv6 register-dns".Split(' ')];

    // vpn.sh's list without the Removed ones and without win-sys, ip-win32 and route-method, which do nothing
    // on macOS but on Windows choose the programs OpenVPN runs as administrator and how it sets up the adapter.
    static readonly HashSet<string> Allowed = [.. ("client pull tls-client dev dev-type proto proto-force remote remote-random remote-random-hostname resolv-retry nobind bind local lport rport port float " +
        "persist-key persist-tun persist-local-ip persist-remote-ip remote-cert-tls remote-cert-eku remote-cert-ku verify-x509-name ns-cert-type peer-fingerprint auth cipher data-ciphers " +
        "data-ciphers-fallback ncp-ciphers ncp-disable compress comp-lzo comp-noadapt allow-compression verb mute mute-replay-warnings link-mtu tun-mtu tun-mtu-extra mssfix fragment mtu-disc " +
        "auth-nocache auth-retry tls-version-min tls-version-max tls-cipher tls-ciphersuites tls-groups tls-cert-profile tls-timeout key-direction keepalive ping ping-restart ping-exit " +
        "ping-timer-rem inactive reneg-sec reneg-bytes reneg-pkts hand-window tran-window connect-retry connect-retry-max connect-timeout server-poll-timeout explicit-exit-notify sndbuf rcvbuf " +
        "socket-flags fast-io tcp-nodelay push-peer-info topology tun-ipv6 route-gateway route-metric route-delay route-nopull route-noexec pull-filter ignore-unknown-option setenv setenv-safe " +
        "allow-recursive-routing replay-window disable-occ ifconfig-nowarn http-proxy http-proxy-option http-proxy-retry socks-proxy socks-proxy-retry").Split(' ')];

    static readonly string[] Blocks = ["ca", "cert", "key", "extra-certs", "tls-auth", "tls-crypt", "tls-crypt-v2"];
    static readonly Regex Comment = new(@"(^|[ \t])[#;].*$"), SetenvName = new(@"^(CLIENT_CERT|FORWARD_COMPATIBLE|PUSH_PEER_INFO|GENERIC_CONFIG|ALLOW_PASSWORD_SAVE|[UI]V_[A-Za-z0-9_]+)$"),
        Tun = new(@"^u?tun[0-9]*$"), Auto = new(@"^auto(-nct)?$");

    public static string Message(string bad) =>
        $"Refusing this profile: AppVPN does not allow '{bad}'. OpenVPN runs as administrator here, so only standard client settings are accepted.";

    /// What the profile contains that is not allowed, or null. Lines are split on \n only, like OpenVPN.
    /// With `removable`, lines that set a Removed directive are listed there (by index) instead of refused.
    public static string? Check(byte[] profile, List<int>? removable = null)
    {
        // Bytes, not characters: Latin-1 keeps every byte as one char. Every comparison below is ordinal for the same reason.
        var lines = Encoding.Latin1.GetString(profile).Split('\n');
        if (lines[^1] == "") lines = lines[..^1];  // the last newline ends a line, it does not start one
        string skip = "";
        bool conn = false;
        static string Name(string s) => s.Length > 2 && s.StartsWith("--", StringComparison.Ordinal) ? s[2..] : s;  // OpenVPN drops a leading -- from a directive

        for (int i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            if (i == 0 && line.StartsWith("\u00EF\u00BB\u00BF", StringComparison.Ordinal)) line = line[3..];  // OpenVPN skips a UTF-8 byte-order mark
            if (line.EndsWith('\r')) line = line[..^1];
            if (line.Length > 249) return "a line longer than 249 characters";  // OpenVPN reads 255 bytes at a time: the rest of a longer line becomes a new "line"
            if (line.Any(c => c < 32 && c != '\t' || c == 127)) return "a control character";  // OpenVPN splits words on \v, \f and \r too
            if (skip != "")
            {
                if (line.TrimStart(' ', '\t').StartsWith($"</{skip}>", StringComparison.Ordinal)) skip = "";  // inside an inline block, which ends at a line that starts with the closing tag
                continue;
            }
            line = Comment.Replace(line, "", 1);  // a word that starts with # or ; begins a comment; what the comment says does not matter
            if (line.IndexOfAny(['"', '\'', '\\']) >= 0) return "quotes or backslashes";  // no quoting rules to copy: with none, a word is text between blanks
            var f = line.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
            string F(int n) => n <= f.Length ? f[n - 1] : "";  // awk's $n
            if (f.Length == 0) continue;
            string w = Name(f[0]);
            int a = 2;
            if (f.Length == 1 && f[0] is "<connection>" or "</connection>") { conn = f[0] == "<connection>"; continue; }
            if (f.Length == 1 && f[0].StartsWith('<') && f[0].EndsWith('>') && Blocks.Contains(f[0][1..^1]))  // only a line that is just the tag opens a block
            {
                if (conn) return f[0] + " inside <connection>";  // OpenVPN ends the connection block first, so the two would disagree on where this one ends
                skip = f[0][1..^1];
                continue;
            }
            if (w == "setenv" && Name(F(2)) == "opt") { w = Name(F(3)); a = 4; if (w == "") return "setenv opt"; }  // "setenv opt X" applies X
            if (w == "setenv" && !SetenvName.IsMatch(Name(F(2)))) return "setenv " + F(2);
            if (w is "http-proxy" or "socks-proxy" && F(a + 2) != "" && !Auto.IsMatch(F(a + 2))) return w + " with a credentials file";
            if (Blocks.Contains(w) && F(a) == "[inline]") continue;
            if (w == "dev" && !Tun.IsMatch(F(a)) || w == "dev-type" && F(a) != "tun") return w + " " + F(a);  // tun only: no device paths
            if (Removed.Contains(w) && removable != null) { removable.Add(i); continue; }
            if (!Allowed.Contains(w)) return w;
        }
        return skip != "" ? $"unterminated <{skip}> block" : null;
    }

    /// The profile as AppVPN stores it on Windows: without the Removed lines, and passing Check. Throws the refusal otherwise.
    public static byte[] Clean(byte[] profile)
    {
        var removable = new List<int>();
        var bad = Check(profile, removable);
        var lines = Encoding.Latin1.GetString(profile).Split('\n').Where((_, i) => !removable.Contains(i));
        var cleaned = Encoding.Latin1.GetBytes(string.Join('\n', lines));
        bad ??= Check(cleaned);  // the exact bytes that will be stored and run
        return bad == null ? cleaned : throw new InvalidDataException(Message(bad));
    }
}
