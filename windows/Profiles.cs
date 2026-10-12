using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Microsoft.VisualBasic.FileIO;

sealed class ProfileException(string message) : Exception(message);

/// The folder is the list: one .ovpn file per profile, named by its display name.
/// It lives under %LOCALAPPDATA%, which only its owner (and administrators) can read.
sealed class ProfileStore(string? dir = null)
{
    static readonly ProfileException TooLarge = new("This file is too large to be an OpenVPN profile.");
    readonly string dir = dir ?? Path.Combine(Vpn.Dir, "ovpn");

    public string[] Names() =>
        Directory.Exists(dir) ? [.. Directory.GetFiles(dir, "*.ovpn").Select(f => Path.GetFileNameWithoutExtension(f)!).Order(StringComparer.CurrentCultureIgnoreCase)] : [];

    public string PathOf(string name) => Path.Combine(dir, name + ".ovpn");

    public string? Remote(string name)
    {
        try
        {
            var words = Words(File.ReadAllText(PathOf(name))).FirstOrDefault(w => w[0] == "remote");
            return words is not { Length: >= 2 } ? null : words.Length >= 3 ? $"{words[1]}:{words[2]}" : words[1];
        }
        catch (IOException) { return null; }
    }

    public string ImportFile(string path) =>
        Add(File.ReadAllBytes(path), Path.GetFileName(path), Path.GetDirectoryName(Path.GetFullPath(path)));

    // ponytail: direct .ovpn links only. OpenVPN Access Server / CloudConnexa login import is not supported.
    public async Task<string> ImportUrl(Uri url)
    {
        static bool Allowed(Uri? u) => u?.Scheme == "https" || (u?.Scheme == "http" && u.Host is "127.0.0.1" or "localhost");
        if (!Allowed(url)) throw new ProfileException("Only https links are allowed.");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));  // in total, also for a server that trickles bytes
        using var http = new HttpClient();
        try
        {
            using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            if (!Allowed(response.RequestMessage?.RequestUri)) throw new ProfileException("The link redirected to a connection that isn't https.");
            if ((int)response.StatusCode != 200) throw new ProfileException($"The server answered {(int)response.StatusCode}.");
            await using var body = await response.Content.ReadAsStreamAsync(deadline.Token);
            var data = new byte[1_000_001];  // never more than the size limit in memory
            int n = 0, r;
            while (n < data.Length && (r = await body.ReadAsync(data.AsMemory(n), deadline.Token)) > 0) n += r;
            var last = Path.GetFileName(url.AbsolutePath);
            return Add(data[..n], last == "" ? url.Host : Uri.UnescapeDataString(last), null);
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException or IOException) { throw new ProfileException("Couldn't download the profile: " + e.Message); }
    }

    public string Rename(string old, string to)
    {
        var name = Sanitize(to);
        if (name == old) return name;
        if (Names().Any(n => n != old && n.Equals(name, StringComparison.CurrentCultureIgnoreCase))) throw new ProfileException($"A profile named \u201C{name}\u201D already exists.");
        // Two steps, so a change of capitals only is not a move onto itself.
        var tmp = PathOf(Guid.NewGuid().ToString());
        File.Move(PathOf(old), tmp);
        File.Move(tmp, PathOf(name));
        return name;
    }

    /// Moves the profile to the Recycle Bin.
    public void Delete(string name) => FileSystem.DeleteFile(PathOf(name), UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);

    string Add(byte[] data, string suggestedName, string? baseDir)
    {
        if (data.Length > 1_000_000) throw TooLarge;
        string raw;
        try { raw = new UTF8Encoding(false, true).GetString(data); }
        catch (DecoderFallbackException) { throw new ProfileException("This file isn't text, so it can't be an OpenVPN profile."); }
        var text = raw.Replace("\r\n", "\n");
        var start = text[..Math.Min(512, text.Length)].ToLowerInvariant();
        if (start.Contains("<html") || start.Contains("<!doctype")) throw new ProfileException("That link returned a web page, not an .ovpn file.");
        var lines = Words(text);
        if (!lines.Any(w => w[0] == "remote")) throw new ProfileException("Not an OpenVPN profile: no remote server line.");
        if (lines.Any(w => w[0] == "auth-user-pass")) throw new ProfileException("This profile needs a username and password, which AppVPN doesn't support yet.");

        // Inline the certificate and key files, so the stored profile is self-contained.
        var result = new List<string>();
        foreach (var line in text.Split('\n'))
        {
            var words = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (words.Length == 0 || words[0][0] is '#' or ';') { result.Add(line); continue; }
            var word = words[0];
            if (word is "pkcs12" or "secret" or "crl-verify" or "askpass") throw new ProfileException($"This profile uses {word}, which AppVPN doesn't support.");
            if (word is not ("ca" or "cert" or "key" or "tls-auth" or "tls-crypt" or "tls-crypt-v2") || words.Length < 2 || words[1] == "[inline]") { result.Add(line); continue; }
            if (baseDir == null || InlineFile(words[1], baseDir) is not { } body)
                throw new ProfileException($"This profile refers to a separate file ({words[1]}). Use a profile with the certificates embedded.");
            result.AddRange([$"<{word}>", body, $"</{word}>"]);
            if (word == "tls-auth" && words.Length >= 3 && words[2] is "0" or "1") result.Add("key-direction " + words[2]);
        }

        // Same rule the app runs at connect time, applied to the exact bytes we store. It also drops the routing and DNS lines.
        byte[] stored;
        try { stored = Allowlist.Clean(Encoding.UTF8.GetBytes(string.Join('\n', result).TrimEnd('\n') + "\n")); }
        catch (InvalidDataException e) { throw new ProfileException(e.Message); }

        var taken = Names().Select(n => n.ToLowerInvariant()).ToHashSet();
        var name = Sanitize(suggestedName);
        // OpenVPN Connect stores profiles under numeric names; the server name says more.
        if (name.All(char.IsDigit) && lines.First(w => w[0] == "remote") is { Length: >= 2 } remote) name = Sanitize(remote[1]);
        var unique = name;
        for (int n = 2; taken.Contains(unique.ToLowerInvariant()); n++) unique = $"{name} {n}";
        Directory.CreateDirectory(dir);
        var tmp = PathOf(unique) + ".tmp";
        File.WriteAllBytes(tmp, stored);
        File.Move(tmp, PathOf(unique));
        return unique;
    }

    /// A file name from any string: no characters or names Windows reserves, no leading dots or spaces, at most 60 characters.
    static string Sanitize(string raw)
    {
        var s = raw.EndsWith(".ovpn", StringComparison.OrdinalIgnoreCase) ? raw[..^5] : raw;
        s = string.Concat(s.Select(c => c < 32 || "\\/:*?\"<>|".Contains(c) ? '-' : c)).TrimStart('.', ' ', '\t');
        s = s[..Math.Min(60, s.Length)].Trim().TrimEnd('.');
        string[] reserved = ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"];
        return s == "" || reserved.Contains(s.Split('.')[0].Trim(), StringComparer.OrdinalIgnoreCase) ? "Profile" : s;
    }

    /// Whitespace-split words of each line, comment lines excluded.
    public static string[][] Words(string text) =>
        [.. text.Split('\n').Select(l => l.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).Where(w => w.Length > 0 && w[0][0] is not ('#' or ';'))];

    /// Only PEM-style files in the profile's own folder: a profile must not be able to pull in other local files.
    static string? InlineFile(string path, string baseDir)
    {
        try
        {
            string real = Real(Path.GetFullPath(path, baseDir)), root = Real(baseDir).TrimEnd('\\') + "\\";
            if (!real.StartsWith(root, StringComparison.OrdinalIgnoreCase) || new FileInfo(real).Length > 1_000_000) return null;
            var text = new UTF8Encoding(false, true).GetString(File.ReadAllBytes(real));
            return text.Contains("-----BEGIN") ? text.Replace("\r\n", "\n").Trim() : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or DecoderFallbackException or ArgumentException or NotSupportedException) { return null; }
    }

    /// The path with every link and junction on the way followed.
    static string Real(string path)
    {
        var full = Path.GetFullPath(path);
        var real = Path.GetPathRoot(full)!;
        foreach (var part in full[real.Length..].Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            real = Path.Combine(real, part);
            FileSystemInfo info = Directory.Exists(real) ? new DirectoryInfo(real) : new FileInfo(real);
            real = info.ResolveLinkTarget(true)?.FullName ?? real;
        }
        return real;
    }

    /// Checks the store against fixtures in `dir`, driven by test.ps1. Returns 1 if any check failed.
    /// The profiles in a Chromium browser's data folder: folder name ("Default", "Profile 1") and the name the browser shows.
    /// The folders are the list, since the browser writes the names to Local State late (a new profile's only when it quits).
    public static List<(string Dir, string Name)> BrowserProfiles(string dataDir)
    {
        var names = new Dictionary<string, string>();
        try
        {
            using var state = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(dataDir, "Local State")));
            foreach (var p in state.RootElement.GetProperty("profile").GetProperty("info_cache").EnumerateObject())
                if (p.Value.TryGetProperty("name", out var name) && name.GetString() is { } shown) names[p.Name] = shown;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException or InvalidOperationException) { }
        try
        {
            return Directory.GetDirectories(dataDir).Select(d => Path.GetFileName(d)).Where(d => d == "Default" || d.StartsWith("Profile "))
                .OrderBy(d => d.Length).ThenBy(d => d, StringComparer.Ordinal).Select(d => (d, names.GetValueOrDefault(d, d))).ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    public static int SelfTest(string dir)
    {
        var store = new ProfileStore(Path.Combine(dir, "store"));
        var fixtures = Path.Combine(dir, "fixtures");
        bool failed = false;
        void Report(string name, bool ok, string detail = "")
        {
            failed |= !ok;
            Console.WriteLine($"{(ok ? "ok  " : "FAIL")} {name}" + (ok || detail == "" ? "" : $" ({detail})"));
        }
        string? Try(Func<string> import, out string error)
        {
            error = "";
            try { return import(); } catch (Exception e) { error = e.Message; return null; }
        }
        string? FileImport(string file, out string error) => Try(() => store.ImportFile(Path.Combine(fixtures, file)), out error);
        // The fixtures over HTTP, for the URL imports.
        var web = new TcpListener(IPAddress.Loopback, 8765);
        web.Start();
        new Thread(() =>
        {
            while (true)
            {
                using var client = web.AcceptTcpClient();
                using var stream = client.GetStream();
                var reader = new StreamReader(stream);
                var file = Path.Combine(fixtures, (reader.ReadLine() ?? "").Split(' ') is [_, var p, ..] ? p.TrimStart('/') : "");
                while (reader.ReadLine() is { Length: > 0 }) { }
                var body = File.Exists(file) ? File.ReadAllBytes(file) : [];
                try
                {
                    stream.Write(Encoding.ASCII.GetBytes($"HTTP/1.1 {(File.Exists(file) ? "200 OK" : "404 Not Found")}\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n"));
                    stream.Write(body);
                }
                catch (IOException) { }  // the import stops reading a file that is too large
            }
        }) { IsBackground = true }.Start();
        string? UrlImport(string link, out string error) => Try(() => Task.Run(() => store.ImportUrl(new Uri(link))).GetAwaiter().GetResult(), out error);
        void Rejected(string name, string phrase, string? imported, string error) =>
            Report(name, imported == null && error.Contains(phrase), imported == null ? error : "was accepted");
        string Stored(string? name) => name == null ? "" : File.ReadAllText(store.PathOf(name));

        Report("import good.ovpn from file", FileImport("good.ovpn", out _) == "good" && store.Names() is ["good"]);
        Report("import again gives 'good 2'", FileImport("good.ovpn", out _) == "good 2");
        bool renamed = Try(() => store.Rename("good 2", "Work"), out _) == "Work";
        Try(() => store.Rename("Work", "GOOD"), out var clash);
        Report("rename good 2 to Work; GOOD clash refused", renamed && clash.Contains("already exists"), clash);
        Report("a rename that only changes capitals works", Try(() => store.Rename("Work", "WORK"), out var caps) == "WORK" && store.Names().Contains("WORK"), caps);
        store.Delete("WORK");
        Report("delete moves it to the Recycle Bin", store.Names() is ["good"]);
        Rejected("route-up directive is refused", "route-up", FileImport("script.ovpn", out var e), e);
        Rejected("quoted directive name is refused", "quotes or backslashes", FileImport("quoted.ovpn", out e), e);
        Rejected("setenv opt cannot smuggle a directive", "'up'", FileImport("setenvopt.ovpn", out e), e);
        Rejected("unknown inline block is refused", "'<up>'", FileImport("block.ovpn", out e), e);
        Rejected("file outside the profile's folder is not inlined", "separate file", FileImport("outside.ovpn", out e), e);
        Report("numeric file name becomes the server name", FileImport("1700000000000.ovpn", out _) == "vpn.example.com");
        var crlf = Stored(FileImport("crlf.ovpn", out _));
        Report("CRLF import leaves no blank lines inside blocks", crlf.Contains("<ca>\nFAKE\nCA\n</ca>"), crlf);
        var routed = Stored(FileImport("routes.ovpn", out e));
        Report("routing and DNS lines are removed, the rest is kept",
               routed.Contains("remote vpn.example.com 1194\n") && routed.Contains("verb 3\n") && !routed.Contains("redirect-gateway") && !routed.Contains("block-outside-dns") && !routed.Contains("dhcp-option"), routed + e);
        Rejected("win-sys is refused", "'win-sys'", FileImport("winsys.ovpn", out e), e);
        Report("a name Windows reserves is not used as a file name", Try(() => store.Rename("good", "NUL"), out e) == "Profile" && Try(() => store.Rename("Profile", "good"), out e) == "good", e);
        Rejected("web page is refused", "web page", FileImport("page.ovpn", out e), e);
        Rejected("missing remote is refused", "no remote server line", FileImport("noremote.ovpn", out e), e);
        Rejected("auth-user-pass is refused", "username and password", FileImport("userpass.ovpn", out e), e);
        var external = FileImport("external.ovpn", out e);
        var stored = Stored(external);
        Report("ca file from disk is inlined", external != null && stored.Contains("<ca>") && stored.Contains("FAKE CA") && !stored.Contains("ca ca.crt"), e);
        Report("URL good.ovpn imports", UrlImport("http://127.0.0.1:8765/good.ovpn", out e) != null, e);
        Rejected("URL with separate ca file is refused", "separate file", UrlImport("http://127.0.0.1:8765/external.ovpn", out e), e);
        Rejected("URL 404 is refused", "404", UrlImport("http://127.0.0.1:8765/missing.ovpn", out e), e);
        Rejected("URL over 1 MB is refused", "too large", UrlImport("http://127.0.0.1:8765/big.ovpn", out e), e);
        Rejected("non-loopback http is refused", "Only https", UrlImport("http://example.com/a.ovpn", out e), e);
        Rejected("file over 1 MB is refused", "too large", FileImport("big.ovpn", out e), e);
        Report("remote of good is host:port", store.Remote("good") == "vpn.example.com:1194", store.Remote("good") ?? "null");
        var browser = string.Join(",", BrowserProfiles(Path.Combine(dir, "browser")).Select(p => $"{p.Dir}={p.Name}"));
        Report("browser profiles are the folders, named by Local State", browser == "Default=Me,Profile 2=Work,Profile 3=Profile 3", browser);
        Report("browser never launched has no profiles", BrowserProfiles(Path.Combine(dir, "missing")).Count == 0);
        return failed ? 1 : 0;
    }
}
