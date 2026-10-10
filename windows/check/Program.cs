// Runs Allowlist over the cases exported from test-cases.sh (the same list vpn.sh's awk check is tested with),
// through the path an import takes (Clean), then the Windows-only rules. Usage: Check <folder of cases>
using System.Text;

int failed = 0, n = 0;
void Report(string name, bool ok, string detail = "")
{
    n++;
    if (!ok) failed++;
    Console.WriteLine($"{(ok ? "ok  " : "FAIL")} {name}" + (ok || detail == "" ? "" : $" ({detail})"));
}
string? Refusal(byte[] profile)
{
    try { Allowlist.Clean(profile); return null; } catch (InvalidDataException e) { return e.Message; }
}

foreach (var expect in Directory.GetFiles(args[0], "*.expect").OrderBy(f => int.Parse(Path.GetFileNameWithoutExtension(f))))
{
    var e = File.ReadAllLines(expect);
    var message = Refusal(File.ReadAllBytes(Path.ChangeExtension(expect, ".ovpn")));
    if (e[0] == "allowed") Report("allowed: " + e[1], message == null, message ?? "");
    else Report("refused: " + e[1], message?.Contains(e[2]) == true, message ?? "was accepted");
}
Report("the shared cases were found", n >= 50, $"{n} cases in {args[0]}");

// Windows only: settings that are harmless on macOS but act on Windows.
byte[] P(string extra) => Encoding.Latin1.GetBytes("client\ndev tun\nremote vpn.example.com 1194\n" + extra);
foreach (var d in new[] { "win-sys C:/x", "ip-win32 netsh", "route-method exe" })
    Report($"refused on Windows: {d}", Refusal(P(d + "\n"))?.Contains($"'{d.Split(' ')[0]}'") == true);
foreach (var d in new[] { "route 10.0.0.0 255.0.0.0", "route-ipv6 ::/0", "redirect-gateway def1", "redirect-private", "dhcp-option DNS 1.1.1.1", "dns server 1 address 1.1.1.1",
                          "block-outside-dns", "block-ipv6", "register-dns", "setenv opt block-outside-dns", "--redirect-gateway def1" })
{
    var stored = Encoding.Latin1.GetString(Allowlist.Clean(P(d + "\nverb 3\n")));
    Report($"removed at import: {d}", stored == "client\ndev tun\nremote vpn.example.com 1194\nverb 3\n", stored);
    Report($"refused at connect: {d}", Allowlist.Check(P(d + "\n")) == d.Replace("setenv opt ", "").TrimStart('-').Split(' ')[0]);
}
var block = "<ca>\nredirect-gateway def1\n</ca>\n";
Report("a removable word inside a certificate block is left alone", Encoding.Latin1.GetString(Allowlist.Clean(P(block))).EndsWith(block));
// A culture-aware comparison would ignore the soft hyphen (byte AD) and end the block one line early.
Report("a closing tag behind a soft hyphen does not end the block", Refusal(P("<ca>\n\u00AD</ca>\nup x\n</ca>\n")) == null && Refusal(P("<ca>\n\u00AD</ca>\n"))?.Contains("unterminated") == true);

Console.WriteLine(failed == 0 ? $"All {n} allowlist checks passed." : $"{failed} of {n} allowlist checks FAILED.");
return failed == 0 ? 0 : 1;
