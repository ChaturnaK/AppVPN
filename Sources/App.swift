import SwiftUI
import UniformTypeIdentifiers

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count { exit(selfTest(interface: args[i + 1])) }
        if let i = args.firstIndex(of: "--selftest-profiles"), i + 1 < args.count { exit(profileSelfTest(dir: args[i + 1])) }
        AppVPNApp.main()
    }
}

struct AppVPNApp: App {
    @StateObject private var vpn = VPN()

    var body: some Scene {
        Window("AppVPN", id: "main") { ContentView().environmentObject(vpn) }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .windowBackgroundDragBehavior(.enabled)
    }
}

/// How much of an app's traffic the proxy can capture without a Network Extension.
enum Coverage {
    case full, partial, envOnly

    init(app: URL) {
        let dir = app.appendingPathComponent("Contents/Frameworks").path
        let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        if frameworks.contains("Electron Framework.framework") {
            self = .partial
        } else if frameworks.contains(where: { $0.hasSuffix(" Framework.framework") && FileManager.default.fileExists(atPath: "\(dir)/\($0)/Helpers") }) {
            self = .full
        } else {
            self = .envOnly
        }
    }

    var symbol: String {
        switch self {
        case .full: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .envOnly: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .full: .green
        case .partial: .secondary
        case .envOnly: .orange
        }
    }

    /// One visible line per level, so the caveat doesn't hide in a tooltip.
    var summary: String {
        switch self {
        case .full: "All traffic and DNS"
        case .partial: "Web traffic only"
        case .envOnly: "May bypass the VPN"
        }
    }

    var help: String {
        switch self {
        case .full: "Chromium browser: all traffic and DNS go through the VPN, in a separate VPN-only profile."
        case .partial: "Electron app: web traffic goes through the VPN. Background Node traffic does only if the app honours proxy variables."
        case .envOnly: "Only proxy variables are set. Apps that ignore them (most native Mac apps) will NOT use the VPN."
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var vpn: VPN
    @AppStorage("selectedProfile") private var selected = ""
    @AppStorage("apps") private var appsRaw = ""
    @State private var relaunch: (app: URL, everyday: String?)?  // everyday: the profile to open in the browser's own data folder
    @State private var profiles: [String] = []
    @State private var showURLSheet = false
    @State private var problem: (title: String, message: String)?
    @State private var hovered: URL?
    @State private var copied = false
    private let store = ProfileStore()

    private var apps: [URL] { appsRaw.split(separator: "\n").map { URL(fileURLWithPath: String($0)) } }
    private let proxyAddr = "127.0.0.1:\(Proxy.port)"

    // `detail` is also the tunnel address while connected, so it only counts as an error once disconnected.
    private var isError: Bool { vpn.state == "DISCONNECTED" && !vpn.busy && !vpn.detail.isEmpty }
    private var inProgress: Bool { vpn.busy || !["DISCONNECTED", "CONNECTED"].contains(vpn.state) }

    private var title: String {
        switch vpn.state {
        case "CONNECTED": "Connected"
        case "DISCONNECTED": vpn.busy ? "Starting…" : isError ? "Connection Failed" : "Not Connected"
        case "RECONNECTING": "Reconnecting…"
        case "EXITING": "Disconnecting…"
        default: "Connecting…"
        }
    }

    private var subtitle: String {
        switch vpn.state {
        case "CONNECTED": vpn.detail
        case "DISCONNECTED":
            vpn.busy ? "Waiting for administrator approval…"
                : isError ? vpn.detail
                : selected.isEmpty ? "Import an OpenVPN profile to get started."
                : "Ready to connect" + (store.remote(selected).map { " to \($0.split(separator: ":")[0])." } ?? ".")
        case "RESOLVE": "Finding the server…"
        case "WAIT", "TCP_CONNECT": "Contacting the server…"
        case "AUTH": "Authenticating…"
        case "GET_CONFIG": "Receiving settings…"
        case "ASSIGN_IP": "Assigning an address…"
        case "RECONNECTING": "Connection lost. Retrying — VPN apps stay offline until it's back."
        case "EXITING": "Shutting down…"
        default: "Starting OpenVPN…"
        }
    }

    /// Symbol, tint and backdrop hues per state: the window's colour is the status at a glance, the title says it in words.
    private var status: (symbol: String, tint: Color, hues: [Color]) {
        if vpn.connected { return ("lock.shield.fill", .green, [.mint, .cyan]) }
        if isError { return ("exclamationmark.shield.fill", .red, [.pink, .orange]) }
        return ("shield.slash.fill", .blue, inProgress ? [.cyan, .indigo] : [.blue, .purple])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            hero
            appsCard
            Button(action: copyShellSettings) {
                Label(copied ? "Copied" : "Copy shell proxy settings", systemImage: copied ? "checkmark" : "terminal")
            }
            .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            .help("Paste into a terminal to send that shell's commands through the VPN.")
        }
        .padding(.horizontal, 28).padding(.top, 48).padding(.bottom, 22)
        .frame(width: 440)
        .background { Backdrop(hues: status.hues) }
        .animation(.smooth(duration: 0.5), value: title)
        .dropDestination(for: URL.self) { urls, _ in
            let ovpn = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "ovpn" }
            importFiles(ovpn)
            return !ovpn.isEmpty
        }
        .onAppear {
            // Migrate the single profile path from before there was a profile list.
            if let old = UserDefaults.standard.string(forKey: "profile"), FileManager.default.fileExists(atPath: old) {
                if let name = try? store.importFile(URL(fileURLWithPath: old)) { selected = name }
                UserDefaults.standard.removeObject(forKey: "profile")
            }
            reload()
        }
        .sheet(isPresented: $showURLSheet) {
            ImportURLSheet(store: store) { name in selected = name; reload() }
        }
        .alert(problem?.title ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(problem?.message ?? "")
        }
        .confirmationDialog(
            relaunchTitle,
            isPresented: Binding(get: { relaunch != nil }, set: { if !$0 { relaunch = nil } }), presenting: relaunch
        ) { item in
            Button("Quit and Relaunch via VPN") { Task { await quitAndRelaunch(item.app, everyday: item.everyday) } }
        } message: { item in
            Text(relaunchMessage(everyday: item.everyday != nil))
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if inProgress {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: status.symbol).font(.system(size: 42, weight: .medium)).foregroundStyle(status.tint.gradient)
                }
            }
            .frame(width: 100, height: 100)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
            .frame(maxWidth: .infinity).padding(.bottom, 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 26, weight: .bold))
                Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 10) {
                // Disconnect comes first: a tunnel left running by an earlier launch must be stoppable even with no profile selected.
                if vpn.state != "DISCONNECTED" {
                    Button("Disconnect") { vpn.disconnect() }.buttonStyle(.glass)
                } else if selected.isEmpty {
                    Button("Import Profile…", action: importFromFile).buttonStyle(.glassProminent).tint(.blue).keyboardShortcut(.defaultAction)
                    Button("From URL…") { showURLSheet = true }.buttonStyle(.glass)
                } else {
                    Button("Connect") { vpn.connect(profile: store.path(selected)) }
                        .buttonStyle(.glassProminent).tint(.blue).keyboardShortcut(.defaultAction).disabled(vpn.busy)
                }
                if !profiles.isEmpty {
                    ProfileMenu(selected: $selected, names: profiles, remote: store.remote(selected),
                                idle: vpn.state == "DISCONNECTED" && !vpn.busy,
                                importFile: importFromFile, importURL: { showURLSheet = true },
                                rename: renameSelected, delete: deleteSelected)
                }
            }
            .controlSize(.extraLarge).padding(.top, 22)
        }
    }

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Apps").font(.title3.weight(.semibold))
                Spacer()
                Button(action: addApps) { Image(systemName: "plus") }
                    .buttonStyle(.glass).buttonBorderShape(.circle).help("Add apps").accessibilityLabel("Add apps")
            }
            Text(apps.isEmpty ? "Add the apps that should use the VPN. Everything else on your Mac keeps its normal connection."
                 : vpn.connected ? "Launched from here, they use the tunnel and are cut off if it drops."
                 : vpn.state != "DISCONNECTED" ? "They stay offline until the tunnel is up."
                 : "Connect, then launch them from here to send them through the tunnel.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !apps.isEmpty {
                // ponytail: fixed row height estimate keeps the window from growing past six apps; swap for a List if rows ever vary.
                ScrollView { VStack(spacing: 0) { ForEach(apps, id: \.self, content: row) } }
                    .frame(height: min(CGFloat(apps.count), 6) * 52).padding(.top, 8)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func row(_ app: URL) -> some View {
        let coverage = Coverage(app: app), name = app.deletingPathExtension().lastPathComponent
        return HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 34, height: 34).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: coverage.symbol).foregroundStyle(coverage.tint)
                    Text(coverage.summary)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine).accessibilityHint(coverage.help).help(coverage.help)
            Spacer()
            Button { remove(app) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovered == app ? 1 : 0)
                .help("Remove from list").accessibilityLabel("Remove \(name)")
            let dataDir = dataDir(app), browserProfiles = dataDir.map(browserProfiles(dataDir:)) ?? []
            let everyday = everydayDir(app).map(browserProfiles(dataDir:)) ?? []
            Group {
                if let dataDir, !browserProfiles.isEmpty || !everyday.isEmpty {
                    // The button itself opens the profile used last; the menu picks one, any number side by side.
                    Menu("Launch") {
                        ForEach(browserProfiles, id: \.dir) { profile in Button(profile.name) { launch(app, profile: profile.dir) } }
                        if !browserProfiles.isEmpty { Divider() }
                        Button("New Profile", systemImage: "plus") {
                            // Chromium creates the profile for a folder name it has not seen. The first one is its "Default".
                            let n = (1...).first { !FileManager.default.fileExists(atPath: "\(dataDir)/Profile \($0)") }!
                            launch(app, profile: browserProfiles.isEmpty ? nil : "Profile \(n)")
                        }
                        if !everyday.isEmpty {
                            // The browser's own profiles, logins and all. One process runs them all, so they cannot sit next to a normal window.
                            Section("Everyday profiles (whole browser on the VPN)") {
                                ForEach(everyday, id: \.dir) { profile in Button(profile.name) { launchEveryday(app, profile: profile.dir) } }
                            }
                        }
                    } primaryAction: { launch(app) }
                    .menuStyle(.button).fixedSize()
                    .id((browserProfiles + everyday).map(\.dir))  // an already built menu does not pick up a new profile otherwise
                } else {
                    Button("Launch") {
                        if coverage != .full, !running(app).isEmpty { relaunch = (app, nil) } else { launch(app) }
                    }
                }
            }
            .buttonStyle(.glass).disabled(!vpn.connected)
            .help(vpn.connected ? "Open \(name) through the VPN" : "Connect to the VPN first")
            .accessibilityLabel("Launch \(name) via VPN")
        }
        .frame(height: 52)
        .contentShape(.rect)
        .onHover { hovered = $0 ? app : nil }
        .contextMenu { Button("Remove from List", systemImage: "trash", role: .destructive) { remove(app) } }
    }

    private func remove(_ app: URL) {
        appsRaw = apps.filter { $0 != app }.map(\.path).joined(separator: "\n")
    }

    private func copyShellSettings() {
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "export ALL_PROXY=socks5h://\(proxyAddr) HTTPS_PROXY=http://\(proxyAddr) HTTP_PROXY=http://\(proxyAddr)", forType: .string)
    }

    private func running(_ app: URL) -> [NSRunningApplication] {
        Bundle(url: app)?.bundleIdentifier.map(NSRunningApplication.runningApplications(withBundleIdentifier:)) ?? []
    }

    /// Where a Chromium browser keeps its VPN-only profiles; nil for other apps.
    private func dataDir(_ app: URL) -> String? {
        guard Coverage(app: app) == .full, let id = Bundle(url: app)?.bundleIdentifier else { return nil }
        return "\(NSHomeDirectory())/.appvpn/profiles/\(id)"
    }

    /// A Chromium browser's own data folder, the one its everyday profiles live in.
    /// ponytail: the browsers listed here; any other shows VPN-only profiles alone. One line adds a browser.
    private func everydayDir(_ app: URL) -> String? {
        let known = ["com.google.Chrome": "Google/Chrome", "com.microsoft.edgemac": "Microsoft Edge", "com.brave.Browser": "BraveSoftware/Brave-Browser",
                     "com.vivaldi.Vivaldi": "Vivaldi", "org.chromium.Chromium": "Chromium"]
        guard Coverage(app: app) == .full, let dir = Bundle(url: app)?.bundleIdentifier.flatMap({ known[$0] }) else { return nil }
        return "\(NSHomeDirectory())/Library/Application Support/\(dir)"
    }

    // Plain strings worked out here, not inside `body`: the compiler on CI gives up on that expression otherwise.
    private var relaunchTitle: String {
        let name = relaunch?.app.deletingPathExtension().lastPathComponent ?? ""
        return "\(name) is already running"
    }

    private func relaunchMessage(everyday: Bool) -> String {
        if !everyday { return "It has to be restarted to pick up the VPN proxy settings." }
        return "Your everyday profiles share one browser, so it has to be restarted, and all of its windows use the VPN until you quit it."
    }

    /// Quits what is running of `app` (for an everyday profile: only the browser on that data folder), then launches it through the VPN.
    private func quitAndRelaunch(_ app: URL, everyday: String?) async {
        let dir = everyday == nil ? nil : everydayDir(app)
        var old = running(app)
        if let dir { old = old.filter { $0.processIdentifier == browserHolder(dataDir: dir) } }
        old.forEach { $0.terminate() }
        // For a data folder its lock decides, as it does for the browser: while a process holds it, a launch only opens a window there, outside the VPN.
        func gone() -> Bool { dir.map { browserHolder(dataDir: $0) == nil } ?? old.allSatisfy(\.isTerminated) }
        for _ in 0..<50 where !gone() { try? await Task.sleep(for: .milliseconds(100)) }
        guard gone() else {
            problem = ("Couldn't Quit \(app.deletingPathExtension().lastPathComponent)", "Quit it yourself, then launch it from here again.")
            return
        }
        launch(app, profile: everyday, in: dir)
    }

    /// Opens an everyday profile. A browser already running on that folder takes over any new window,
    /// so unless it was itself started through the VPN it has to quit first.
    private func launchEveryday(_ app: URL, profile: String) {
        guard let dir = everydayDir(app) else { return }
        if let pid = browserHolder(dataDir: dir) {
            let ps = Process(), out = Pipe()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-ww", "-o", "args=", "-p", "\(pid)"]
            ps.standardOutput = out
            try? ps.run()
            let args = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard args.contains("--proxy-server=socks5://\(proxyAddr)") else { relaunch = (app, profile); return }
        }
        launch(app, profile: profile, in: dir)
    }

    /// `dir` is the data folder for a browser; left out, it is the VPN-only one.
    private func launch(_ app: URL, profile: String? = nil, in dir: String? = nil) {
        var args = ["-n", "-a", app.path]
        for name in ["ALL_PROXY", "all_proxy"] { args += ["--env", "\(name)=socks5h://\(proxyAddr)"] }
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] { args += ["--env", "\(name)=http://\(proxyAddr)"] }
        let coverage = Coverage(app: app)
        if coverage != .envOnly {
            // Chromium switches: proxy everything, resolve no names locally, no WebRTC UDP around the proxy.
            args += ["--args", "--proxy-server=socks5://\(proxyAddr)", "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1",
                     "--force-webrtc-ip-handling-policy=disable_non_proxied_udp"]
            if let dataDir = dir ?? dataDir(app) {
                // Own data folder by default, so a VPN window can run next to the normal browser instead of joining it.
                args.append("--user-data-dir=\(dataDir)")
                if let profile { args.append("--profile-directory=\(profile)") }
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        try? p.run()
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ovpn") ?? .data]
        panel.allowsMultipleSelection = true
        if profiles.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/OpenVPN Connect/profiles")
        }
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    private func importFiles(_ urls: [URL]) {
        var last: String?, failures: [String] = []
        for url in urls {
            do { last = try store.importFile(url) } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if let last, vpn.state == "DISCONNECTED", !vpn.busy { selected = last }  // don't relabel a live connection
        reload()
        if !failures.isEmpty { problem = ("Couldn't Import Profile", failures.joined(separator: "\n")) }
    }

    private func reload() {
        profiles = store.names()
        if !profiles.contains(selected) { selected = profiles.first ?? "" }
    }

    private func renameSelected(_ name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do { selected = try store.rename(selected, to: name) } catch { problem = ("Couldn't Rename Profile", error.localizedDescription) }
        reload()
    }

    private func deleteSelected() {
        do { try store.delete(selected) } catch { problem = ("Couldn't Delete Profile", error.localizedDescription) }
        reload()
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK {
            appsRaw = (apps + panel.urls.filter { !apps.contains($0) }).map(\.path).joined(separator: "\n")
        }
    }
}

/// Soft two-hue wash that fades out towards the bottom, for the glass to sit on.
private struct Backdrop: View {
    let hues: [Color]

    var body: some View {
        let a = hues[0], b = hues[1]
        MeshGradient(width: 3, height: 3,
                     points: [[0, 0], [0.5, 0], [1, 0], [0, 0.4], [0.6, 0.35], [1, 0.45], [0, 1], [0.5, 1], [1, 1]],
                     colors: [a.opacity(0.5), b.opacity(0.35), b.opacity(0.6),
                              a.opacity(0.2), b.opacity(0.25), a.opacity(0.3),
                              a.opacity(0), b.opacity(0), a.opacity(0)])
            .background(Color(nsColor: .windowBackgroundColor))
            .ignoresSafeArea()
    }
}
