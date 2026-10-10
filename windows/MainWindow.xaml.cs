using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace AppVPN;

/// How much of an app's traffic the proxy can capture: Windows has no per-app VPN for ordinary programs either.
enum Coverage { Full, Partial, EnvOnly }

/// An icon-font glyph. It is decoration next to text that says the same, so screen readers don't get to see it.
public sealed class Icon : TextBlock
{
    protected override AutomationPeer? OnCreateAutomationPeer() => null;
}

/// One row of the app list.
record AppRow(string Path, string Name, ImageSource? Icon, Coverage Coverage, bool CanLaunch)
{
    public override string ToString() => $"{Name}, {Summary}";  // what a screen reader calls the row
    public string Symbol => Coverage switch { Coverage.Full => "\uE73E", Coverage.Partial => "\uE774", _ => "\uE7BA" };
    public Brush Tint => Coverage switch { Coverage.Full => Brushes.Green, Coverage.Partial => Brushes.Gray, _ => Brushes.DarkOrange };
    /// One visible line per level, so the caveat doesn't hide in a tooltip.
    public string Summary => Coverage switch { Coverage.Full => "All traffic and DNS", Coverage.Partial => "Web traffic only", _ => "May bypass the VPN" };
    public string Help => Coverage switch
    {
        Coverage.Full => "Chromium browser: all traffic and DNS go through the VPN, in a separate VPN-only profile.",
        Coverage.Partial => "Electron app: web traffic goes through the VPN. Background Node traffic does only if the app honours proxy variables.",
        _ => "Only proxy variables are set. Apps that ignore them (most Windows apps) will NOT use the VPN.",
    };
    public string LaunchHelp => CanLaunch ? $"Open {Name} through the VPN" : "Connect to the VPN first";
    public string LaunchLabel => $"Launch {Name} via VPN";
    public string RemoveLabel => $"Remove {Name}";
}

sealed class Settings
{
    static string File => System.IO.Path.Combine(Vpn.Dir, "settings.json");
    public string Selected { get; set; } = "";
    public List<string> Apps { get; set; } = [];

    public static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(System.IO.File.ReadAllText(File)) ?? new(); }
        catch (Exception e) when (e is IOException or JsonException) { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(Vpn.Dir);
        System.IO.File.WriteAllText(File, JsonSerializer.Serialize(this));
    }
}

public partial class MainWindow : Window
{
    const string ProxyAddr = "127.0.0.1:18964";
    readonly Vpn vpn = new();
    readonly ProfileStore store = new();
    readonly Settings settings = Settings.Load();
    readonly Dictionary<string, ImageSource?> icons = [];
    string[] profiles = [];

    bool Idle => vpn.State == "DISCONNECTED" && !vpn.Busy;

    public MainWindow()
    {
        InitializeComponent();
        vpn.Changed += Render;
        Reload();
    }

    void Render()
    {
        // `Detail` is also the tunnel address while connected, so it only counts as an error once disconnected.
        bool isError = Idle && vpn.Detail != "";
        bool inProgress = vpn.Busy || vpn.State is not ("DISCONNECTED" or "CONNECTED");
        var selected = settings.Selected;

        TitleText.Text = vpn.State switch
        {
            "CONNECTED" => "Connected",
            "DISCONNECTED" => vpn.Busy ? "Starting…" : isError ? "Connection Failed" : "Not Connected",
            "RECONNECTING" => "Reconnecting…",
            "EXITING" => "Disconnecting…",
            _ => "Connecting…",
        };
        Subtitle.Text = vpn.State switch
        {
            "CONNECTED" => vpn.Detail,
            "DISCONNECTED" => vpn.Busy ? "Waiting for administrator approval…"
                : isError ? vpn.Detail
                : selected == "" ? "Import an OpenVPN profile to get started."
                : "Ready to connect" + (store.Remote(selected) is { } remote ? $" to {remote.Split(':')[0]}." : "."),
            "RESOLVE" => "Finding the server…",
            "WAIT" or "TCP_CONNECT" => "Contacting the server…",
            "AUTH" => "Authenticating…",
            "GET_CONFIG" => "Receiving settings…",
            "ASSIGN_IP" => "Assigning an address…",
            "RECONNECTING" => "Connection lost. Retrying — VPN apps stay offline until it's back.",
            "EXITING" => "Shutting down…",
            _ => "Starting OpenVPN…",
        };

        // Symbol and colour per state: the status at a glance, the title says it in words.
        (Glyph.Text, Glyph.Foreground) = vpn.Connected ? ("\uE72E", Brushes.Green) : isError ? ("\uE783", Brushes.Crimson) : ("\uEA18", (Brush)Brushes.DodgerBlue);
        Glyph.Visibility = inProgress ? Visibility.Hidden : Visibility.Visible;
        Spinner.Visibility = inProgress ? Visibility.Visible : Visibility.Hidden;

        // Disconnect comes first: a tunnel left running by an earlier launch must be stoppable even with no profile selected.
        bool up = vpn.State != "DISCONNECTED";
        Primary.Content = up ? "Disconnect" : selected == "" ? "Import Profile…" : "Connect";
        Primary.IsEnabled = up || !vpn.Busy;
        Primary.IsDefault = !up;
        Primary.Style = up ? (Style)FindResource(typeof(Button)) : (Style)FindResource("AccentButtonStyle");
        FromUrl.Visibility = !up && selected == "" ? Visibility.Visible : Visibility.Collapsed;
        ProfileButton.Visibility = profiles.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ProfileName.Text = selected;
        ProfileButton.ToolTip = (store.Remote(selected) is { } server ? $"Server: {server}" : "Profile") + (Idle ? "" : ". Disconnect to switch profiles.");
        System.Windows.Automation.AutomationProperties.SetName(ProfileButton, $"Profile: {selected}");

        AppsHint.Text = settings.Apps.Count == 0 ? "Add the apps that should use the VPN. Everything else on your PC keeps its normal connection."
            : vpn.Connected ? "Launched from here, they use the tunnel and are cut off if it drops."
            : up ? "They stay offline until the tunnel is up."
            : "Connect, then launch them from here to send them through the tunnel.";
        AppScroll.Visibility = settings.Apps.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        AppList.ItemsSource = settings.Apps.Select(app => new AppRow(app, NameOf(app), IconOf(app), CoverageOf(app), vpn.Connected)).ToList();
    }

    void Reload()
    {
        profiles = store.Names();
        if (!profiles.Contains(settings.Selected)) settings.Selected = profiles.FirstOrDefault() ?? "";
        settings.Save();
        Render();
    }

    void Problem(string title, string message) => MessageBox.Show(this, message, title, MessageBoxButton.OK, MessageBoxImage.Warning);

    // Profiles

    void OnPrimary(object sender, RoutedEventArgs e)
    {
        if (vpn.State != "DISCONNECTED") vpn.Disconnect();
        else if (settings.Selected == "") ImportFromFile();
        else vpn.Connect(store.PathOf(settings.Selected));
    }

    void OnImportUrl(object sender, RoutedEventArgs e) => ImportFromUrl();

    void OnProfileMenu(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = ProfileButton, Placement = PlacementMode.Bottom };
        void Add(string header, Action action, bool enabled = true)
        {
            var item = new MenuItem { Header = header, IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        foreach (var name in profiles)
        {
            var item = new MenuItem { Header = name.Replace("_", "__"), IsCheckable = true, IsChecked = name == settings.Selected, IsEnabled = Idle };
            item.Click += (_, _) => { settings.Selected = name; Reload(); };
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());
        Add("Import from File…", ImportFromFile);
        Add("Import from URL…", ImportFromUrl);
        menu.Items.Add(new Separator());
        Add("Rename…", RenameSelected, Idle);
        Add("Delete…", DeleteSelected, Idle);
        menu.IsOpen = true;
    }

    void ImportFromFile()
    {
        var dialog = new OpenFileDialog { Filter = "OpenVPN profiles (*.ovpn)|*.ovpn", Multiselect = true };
        if (profiles.Length == 0)
        {
            // Where OpenVPN Connect and OpenVPN GUI keep theirs.
            string[] usual = [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"OpenVPN Connect\profiles"),
                              Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), @"OpenVPN\config")];
            if (usual.FirstOrDefault(Directory.Exists) is { } dir) dialog.InitialDirectory = dir;
        }
        if (dialog.ShowDialog(this) == true) ImportFiles(dialog.FileNames);
    }

    void ImportFiles(IEnumerable<string> files)
    {
        string? last = null;
        var failures = new List<string>();
        foreach (var file in files)
        {
            try { last = store.ImportFile(file); }
            catch (Exception e) when (e is ProfileException or IOException or UnauthorizedAccessException) { failures.Add($"{Path.GetFileName(file)}: {e.Message}"); }
        }
        if (last != null && Idle) settings.Selected = last;  // don't relabel a live connection
        Reload();
        if (failures.Count > 0) Problem("Couldn't Import Profile", string.Join("\n", failures));
    }

    async void ImportFromUrl()
    {
        if (Prompt("Import Profile from URL", "A direct https link to an .ovpn file.", "") is not { Length: > 0 } link) return;
        if (!Uri.TryCreate(link, UriKind.Absolute, out var url) || url.Host == "") { Problem("Couldn't Import Profile", "That doesn't look like a link."); return; }
        try
        {
            IsEnabled = false;
            var name = await store.ImportUrl(url);
            if (Idle) settings.Selected = name;
        }
        catch (Exception e) when (e is ProfileException or IOException or UnauthorizedAccessException) { Problem("Couldn't Import Profile", e.Message); }
        finally { IsEnabled = true; }
        Reload();
    }

    void RenameSelected()
    {
        if (Prompt("Rename Profile", "Name", settings.Selected) is not { Length: > 0 } name) return;
        try { settings.Selected = store.Rename(settings.Selected, name); }
        catch (Exception e) when (e is ProfileException or IOException or UnauthorizedAccessException) { Problem("Couldn't Rename Profile", e.Message); }
        Reload();
    }

    void DeleteSelected()
    {
        if (MessageBox.Show(this, "The profile will be moved to the Recycle Bin.", $"Delete “{settings.Selected}”?", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        try { store.Delete(settings.Selected); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or OperationCanceledException) { Problem("Couldn't Delete Profile", e.Message); }
        Reload();
    }

    /// A small window asking for one line of text. Null if cancelled.
    string? Prompt(string title, string label, string initial)
    {
        var box = new TextBox { Text = initial, Margin = new Thickness(0, 8, 0, 16) };
        var ok = new Button { Content = "OK", IsDefault = true, Padding = new Thickness(18, 6, 18, 6), Style = (Style)FindResource("AccentButtonStyle") };
        var cancel = new Button { Content = "Cancel", IsCancel = true, Padding = new Thickness(18, 6, 18, 6), Margin = new Thickness(0, 0, 8, 0) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { cancel, ok } };
        var window = new Window
        {
            Title = title, Owner = this, Width = 420, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
            Content = new StackPanel { Margin = new Thickness(20), Children = { new TextBlock { Text = label }, box, buttons } },
        };
        ok.Click += (_, _) => window.DialogResult = true;
        box.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        return window.ShowDialog() == true ? box.Text.Trim() : null;
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetData(DataFormats.FileDrop) is string[] files && files.Any(IsProfile) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] files) ImportFiles(files.Where(IsProfile));
    }

    static bool IsProfile(string file) => file.EndsWith(".ovpn", StringComparison.OrdinalIgnoreCase);

    // Apps

    void OnAddApps(object sender, RoutedEventArgs e)
    {
        // Opens in the Start menu, where every installed app has a shortcut; the dialog hands back the program a shortcut points to.
        var dialog = new OpenFileDialog
        {
            Filter = "Apps|*.exe;*.lnk", Multiselect = true,
            InitialDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu), "Programs"),
        };
        if (dialog.ShowDialog(this) != true) return;
        settings.Apps.AddRange(dialog.FileNames.Where(f => f.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && !settings.Apps.Contains(f, StringComparer.OrdinalIgnoreCase)));
        settings.Save();
        Render();
    }

    void OnRemove(object sender, RoutedEventArgs e)
    {
        settings.Apps.Remove(((AppRow)((FrameworkElement)sender).Tag).Path);
        settings.Save();
        Render();
    }

    async void OnLaunch(object sender, RoutedEventArgs e)
    {
        var app = (AppRow)((FrameworkElement)sender).Tag;
        if (app.Coverage != Coverage.Full && Running(app.Path).Length > 0)
        {
            if (MessageBox.Show(this, "It has to be restarted to pick up the VPN proxy settings.\n\nQuit and relaunch via VPN?", $"{app.Name} is already running",
                                MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
            foreach (var p in Running(app.Path)) p.CloseMainWindow();
            for (int i = 0; i < 50 && Running(app.Path).Length > 0; i++) await Task.Delay(100);
        }
        Launch(app.Path);
    }

    /// The product name the program carries ("Microsoft Edge"), or its file name.
    static string NameOf(string app)
    {
        try { if (FileVersionInfo.GetVersionInfo(app).FileDescription is { Length: > 0 } name) return name; } catch (IOException) { }
        return Path.GetFileNameWithoutExtension(app);
    }

    static Process[] Running(string app) => Process.GetProcessesByName(Path.GetFileNameWithoutExtension(app));

    void Launch(string app)
    {
        var start = new ProcessStartInfo(app) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(app) };
        start.Environment["ALL_PROXY"] = $"socks5h://{ProxyAddr}";
        start.Environment["HTTP_PROXY"] = start.Environment["HTTPS_PROXY"] = $"http://{ProxyAddr}";
        var coverage = CoverageOf(app);
        if (coverage != Coverage.EnvOnly)
        {
            // Chromium switches: proxy everything, resolve no names locally, no WebRTC UDP around the proxy.
            start.ArgumentList.Add($"--proxy-server=socks5://{ProxyAddr}");
            start.ArgumentList.Add("--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1");
            start.ArgumentList.Add("--force-webrtc-ip-handling-policy=disable_non_proxied_udp");
            // Own profile, so a VPN window can run next to the normal browser instead of joining it.
            if (coverage == Coverage.Full) start.ArgumentList.Add($"--user-data-dir={Path.Combine(Vpn.Dir, "profiles", Path.GetFileNameWithoutExtension(app))}");
        }
        try { Process.Start(start)?.Dispose(); }
        catch (Win32Exception e) { Problem($"Couldn't Launch {NameOf(app)}", e.Message); }
    }

    /// Electron apps carry resources\app.asar (or an unpacked resources\app); Chromium browsers carry chrome_elf.dll
    /// (msedge_elf.dll). Either sits beside the program or one folder down, in a version folder.
    static Coverage CoverageOf(string app)
    {
        try
        {
            var dir = Path.GetDirectoryName(app)!;
            string[] dirs = [dir, .. Directory.GetDirectories(dir)];
            if (dirs.Any(d => File.Exists(Path.Combine(d, @"resources\app.asar")) || Directory.Exists(Path.Combine(d, @"resources\app")))) return Coverage.Partial;
            if (dirs.Any(d => Directory.EnumerateFiles(d, "*_elf.dll").Any())) return Coverage.Full;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return Coverage.EnvOnly;
    }

    ImageSource? IconOf(string app)
    {
        if (icons.TryGetValue(app, out var cached)) return cached;
        try
        {
            using var icon = System.Drawing.Icon.ExtractAssociatedIcon(app);
            return icons[app] = icon == null ? null : Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
        }
        catch (Exception e) when (e is IOException or ArgumentException) { return icons[app] = null; }
    }

    async void OnCopyShell(object sender, RoutedEventArgs e)
    {
        Clipboard.SetText($"$env:ALL_PROXY='socks5h://{ProxyAddr}'; $env:HTTPS_PROXY='http://{ProxyAddr}'; $env:HTTP_PROXY='http://{ProxyAddr}'");
        CopyButton.Content = "Copied";
        await Task.Delay(1500);
        CopyButton.Content = "Copy shell proxy settings";
    }
}
