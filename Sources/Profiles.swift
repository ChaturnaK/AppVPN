import Foundation
import SwiftUI

struct ProfileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private let tooLargeError = ProfileError(message: "This file is too large to be an OpenVPN profile.")

/// The folder is the list: one .ovpn file per profile, named by its display name.
struct ProfileStore {
    var dir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".appvpn/ovpn")

    func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".ovpn") }.map { String($0.dropLast(5)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func path(_ name: String) -> String { dir.appendingPathComponent(name + ".ovpn").path }

    func remote(_ name: String) -> String? {
        guard let text = try? String(contentsOfFile: path(name), encoding: .utf8),
              let words = words(in: text).first(where: { $0.first == "remote" }), words.count >= 2 else { return nil }
        return words.count >= 3 ? "\(words[1]):\(words[2])" : words[1]
    }

    @discardableResult func importFile(_ url: URL) throws -> String {
        try add(data: Data(contentsOf: url), suggestedName: url.lastPathComponent, baseDir: url.deletingLastPathComponent())
    }

    // ponytail: direct .ovpn links only, body is buffered before the size check. OpenVPN Access Server / CloudConnexa login import is not supported.
    @discardableResult func importURL(_ url: URL) async throws -> String {
        func allowed(_ u: URL?) -> Bool { u?.scheme == "https" || (u?.scheme == "http" && ["127.0.0.1", "localhost"].contains(u?.host ?? "")) }
        guard allowed(url) else { throw ProfileError(message: "Only https links are allowed.") }
        // The resource timeout is a total deadline; the per-request one resets with every byte a slow server trickles.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 20
        let (data, response) = try await URLSession(configuration: config).data(from: url)
        guard let http = response as? HTTPURLResponse else { throw ProfileError(message: "The server didn't answer with HTTP.") }
        guard allowed(http.url) else { throw ProfileError(message: "The link redirected to a connection that isn't https.") }
        guard http.statusCode == 200 else { throw ProfileError(message: "The server answered \(http.statusCode).") }
        guard response.expectedContentLength <= 1_000_000 else { throw tooLargeError }
        let last = url.lastPathComponent
        return try add(data: data, suggestedName: last.isEmpty || last == "/" ? url.host ?? "" : last, baseDir: nil)
    }

    @discardableResult func rename(_ old: String, to new: String) throws -> String {
        let name = sanitize(new)
        if name == old { return name }
        guard !names().contains(where: { $0 != old && $0.lowercased() == name.lowercased() }) else {
            throw ProfileError(message: "A profile named “\(name)” already exists.")
        }
        try FileManager.default.moveItem(at: URL(fileURLWithPath: path(old)), to: URL(fileURLWithPath: path(name)))
        return name
    }

    /// Moves the profile to the Trash and returns where it went.
    @discardableResult func delete(_ name: String) throws -> URL? {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path(name)), resultingItemURL: &trashed)
        return trashed as URL?
    }

    private func add(data: Data, suggestedName: String, baseDir: URL?) throws -> String {
        guard data.count <= 1_000_000 else { throw tooLargeError }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ProfileError(message: "This file isn't text, so it can't be an OpenVPN profile.")
        }
        // CRLF would otherwise split into two breaks below and put blank lines inside PEM blocks, which OpenSSL rejects.
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard !text.prefix(512).lowercased().contains("<html"), !text.prefix(512).lowercased().contains("<!doctype") else {
            throw ProfileError(message: "That link returned a web page, not an .ovpn file.")
        }
        let lines = words(in: text)
        guard lines.contains(where: { $0.first == "remote" }) else {
            throw ProfileError(message: "Not an OpenVPN profile: no remote server line.")
        }
        guard !lines.contains(where: { $0.first == "auth-user-pass" }) else {
            throw ProfileError(message: "This profile needs a username and password, which AppVPN doesn't support yet.")
        }

        // Inline the certificate and key files, so the stored profile is self-contained.
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let words = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let word = words.first, !word.hasPrefix("#"), !word.hasPrefix(";") else { out.append(raw); continue }
            if ["pkcs12", "secret", "crl-verify", "askpass"].contains(word) {
                throw ProfileError(message: "This profile uses \(word), which AppVPN doesn't support.")
            }
            guard ["ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2"].contains(word), words.count >= 2, words[1] != "[inline]" else {
                out.append(raw); continue
            }
            guard let baseDir, let body = inlineFile(words[1], relativeTo: baseDir) else {
                throw ProfileError(message: "This profile refers to a separate file (\(words[1])). Use a profile with the certificates embedded.")
            }
            out += ["<\(word)>", body, "</\(word)>"]
            if word == "tls-auth", words.count >= 3, ["0", "1"].contains(words[2]) { out.append("key-direction \(words[2])") }
        }
        let result = out.joined(separator: "\n") + "\n"

        // Same refused-directive rule the app runs at connect time, applied to the exact text we would store.
        guard let script = Bundle.main.path(forResource: "vpn", ofType: "sh") else {
            throw ProfileError(message: "vpn.sh is missing from the app bundle, so the profile can't be checked.")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ovpn")
        guard FileManager.default.createFile(atPath: tmp.path, contents: Data(result.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ProfileError(message: "Couldn't write a temporary file to check the profile.")
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let check = Process(), stderr = Pipe()
        check.executableURL = URL(fileURLWithPath: script)
        check.arguments = ["check", tmp.path]
        check.standardError = stderr
        try check.run()
        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        check.waitUntilExit()
        guard check.terminationStatus == 0 else { throw ProfileError(message: message.trimmingCharacters(in: .whitespacesAndNewlines)) }

        let taken = Set(names().map { $0.lowercased() })
        var base = sanitize(suggestedName)
        // OpenVPN Connect stores profiles under numeric names; the server name says more.
        if base.allSatisfy(\.isNumber), let host = lines.first(where: { $0.first == "remote" })?.dropFirst().first { base = sanitize(host) }
        var name = base, n = 2
        while taken.contains(name.lowercased()) { name = "\(base) \(n)"; n += 1 }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent(name + ".ovpn")
        try Data(result.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return name
    }

    /// A file name from any string: no path separators, no leading dots or spaces, at most 60 characters.
    private func sanitize(_ raw: String) -> String {
        var s = raw.lowercased().hasSuffix(".ovpn") ? String(raw.dropLast(5)) : raw
        s = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = String(s.drop(while: { $0 == "." || $0.isWhitespace }))
        s = String(s.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Profile" : s
    }

    /// Whitespace-split words of each line, comment lines excluded.
    private func words(in text: String) -> [[String]] {
        text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
            .filter { $0.first.map { !$0.hasPrefix("#") && !$0.hasPrefix(";") } ?? false }
    }

    /// Only PEM-style files in the profile's own folder: a profile must not be able to pull in other local files.
    private func inlineFile(_ path: String, relativeTo base: URL) -> String? {
        let file = URL(fileURLWithPath: path, relativeTo: base).resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.resolvingSymlinksInPath().path + "/"),
              let data = try? Data(contentsOf: file), data.count <= 1_000_000,
              let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One glass pill for everything about profiles: pick, import, rename, delete.
struct ProfileMenu: View {
    @Binding var selected: String
    let names: [String]
    let remote: String?
    let idle: Bool
    let importFile: () -> Void
    let importURL: () -> Void
    let rename: (String) -> Void
    let delete: () -> Void

    @State var renaming = false
    @State var newName = ""
    @State var deleting = false

    var body: some View {
        Menu {
            Picker("Profile", selection: $selected) {
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline).disabled(!idle)
            Divider()
            Button("Import from File…", systemImage: "doc.badge.plus", action: importFile)
            Button("Import from URL…", systemImage: "link", action: importURL)
            Divider()
            Button("Rename…", systemImage: "pencil") { newName = selected; renaming = true }.disabled(!idle)
            Button("Delete…", systemImage: "trash", role: .destructive) { deleting = true }.disabled(!idle)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                Text(selected).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).frame(height: 36).contentShape(.capsule)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(maxWidth: 220, alignment: .leading)  // a long name must truncate, not widen the window
        .help((remote.map { "Server: \($0)" } ?? "Profile") + (idle ? "" : ". Disconnect to switch profiles."))
        .accessibilityLabel("Profile: \(selected)")
        .alert("Rename Profile", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { rename(newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(selected)”?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("The profile will be moved to the Trash.")
        }
    }
}

/// Sheet for importing a direct https link to an .ovpn file.
struct ImportURLSheet: View {
    let store: ProfileStore
    let onImport: (String) -> Void
    @Environment(\.dismiss) var dismiss
    @State var link = ""
    @State var busy = false
    @State var error: String?
    @State var task: Task<Void, Never>?
    @FocusState var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Profile from URL").font(.headline)
            TextField("", text: $link, prompt: Text("https://example.com/client.ovpn"))
                .textFieldStyle(.roundedBorder).focused($focused)
            Text("A direct https link to an .ovpn file.").font(.caption).foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import", action: run).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { focused = true }
    }

    private func run() {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)), url.host != nil else {
            error = "That doesn't look like a link."
            return
        }
        busy = true
        error = nil
        task = Task {
            do {
                let name = try await store.importURL(url)
                guard !Task.isCancelled else { return }  // Cancel was pressed while the download was running
                onImport(name)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// The profiles in a Chromium browser's data folder: folder name ("Default", "Profile 1") and the name the browser shows.
/// The folders are the list, since the browser writes the names to Local State late (a new profile's only when it quits).
func browserProfiles(dataDir: String) -> [(dir: String, name: String)] {
    let state = FileManager.default.contents(atPath: dataDir + "/Local State").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let cache = (state?["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] ?? [:]
    let dirs = (try? FileManager.default.contentsOfDirectory(atPath: dataDir)) ?? []
    return dirs.filter { $0 == "Default" || $0.hasPrefix("Profile ") }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        .map { (dir: $0, name: cache[$0]?["name"] as? String ?? $0) }
}

private final class ResultBox { var value: Result<String, Error> = .failure(ProfileError(message: "no result")) }

/// Checks the store against fixtures in `dir`, driven by test-profiles.sh. Returns 1 if any check failed.
func profileSelfTest(dir: String) -> Int32 {
    let store = ProfileStore(dir: URL(fileURLWithPath: dir + "/store"))
    let fixtures = dir + "/fixtures/"
    var failed = false
    func report(_ name: String, _ ok: Bool, _ detail: String = "") {
        failed = failed || !ok
        print("\(ok ? "ok  " : "FAIL") \(name)" + (ok || detail.isEmpty ? "" : " (\(detail))"))
    }
    func fileImport(_ file: String) -> Result<String, Error> {
        Result { try store.importFile(URL(fileURLWithPath: fixtures + file)) }
    }
    func urlImport(_ link: String) -> Result<String, Error> {
        let box = ResultBox(), done = DispatchSemaphore(value: 0), url = URL(string: link)!
        Task {
            do { box.value = .success(try await store.importURL(url)) } catch { box.value = .failure(error) }
            done.signal()
        }
        done.wait()
        return box.value
    }
    func rejected(_ name: String, _ phrase: String, _ result: Result<String, Error>) {
        switch result {
        case .success: report(name, false, "was accepted")
        case .failure(let e): report(name, e.localizedDescription.contains(phrase), e.localizedDescription)
        }
    }
    func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? -1
    }

    let good = store.path("good")
    report("import good.ovpn from file, 0600 file in 0700 folder",
           (try? fileImport("good.ovpn").get()) == "good" && store.names() == ["good"]
               && mode(good) == 0o600 && mode(dir + "/store") == 0o700)
    report("import again gives 'good 2'", (try? fileImport("good.ovpn").get()) == "good 2")
    let renamed = (try? Result { try store.rename("good 2", to: "Work") }.get()) == "Work"
    var clash = "succeeded"
    if case .failure(let e) = Result(catching: { try store.rename("Work", to: "GOOD") }) { clash = e.localizedDescription }
    report("rename good 2 to Work; GOOD clash refused", renamed && clash.contains("already exists"), clash)
    let trashed = try? store.delete("Work")
    report("delete Work moves it to the Trash", trashed != nil && store.names() == ["good"])
    if let trashed { try? FileManager.default.removeItem(at: trashed) }  // our own dummy file: keep the Trash clean
    rejected("route-up directive is refused", "route-up", fileImport("script.ovpn"))
    rejected("quoted directive name is refused", "quotes or backslashes", fileImport("quoted.ovpn"))
    rejected("setenv opt cannot smuggle a directive", "'up'", fileImport("setenvopt.ovpn"))
    rejected("unknown inline block is refused", "'<up>'", fileImport("block.ovpn"))
    rejected("file outside the profile's folder is not inlined", "separate file", fileImport("outside.ovpn"))
    report("numeric file name becomes the server name", (try? fileImport("1700000000000.ovpn").get()) == "vpn.example.com")
    let crlf = fileImport("crlf.ovpn")
    let crlfStored = (try? crlf.get()).flatMap { try? String(contentsOfFile: store.path($0), encoding: .utf8) } ?? ""
    report("CRLF import leaves no blank lines inside blocks", crlfStored.contains("<ca>\nFAKE\nCA\n</ca>"), crlfStored)
    rejected("web page is refused", "web page", fileImport("page.ovpn"))
    rejected("missing remote is refused", "no remote server line", fileImport("noremote.ovpn"))
    rejected("auth-user-pass is refused", "username and password", fileImport("userpass.ovpn"))
    let external = fileImport("external.ovpn")
    let stored = (try? external.get()).flatMap { try? String(contentsOfFile: store.path($0), encoding: .utf8) } ?? ""
    report("ca file from disk is inlined", (try? external.get()) != nil && stored.contains("<ca>") && stored.contains("FAKE CA") && !stored.contains("ca ca.crt"))
    report("URL good.ovpn imports", (try? urlImport("http://127.0.0.1:8765/good.ovpn").get()) != nil)
    rejected("URL with separate ca file is refused", "separate file", urlImport("http://127.0.0.1:8765/external.ovpn"))
    rejected("URL 404 is refused", "404", urlImport("http://127.0.0.1:8765/missing.ovpn"))
    rejected("non-loopback http is refused", "Only https", urlImport("http://example.com/a.ovpn"))
    rejected("file over 1 MB is refused", "too large", fileImport("big.ovpn"))
    report("remote of good is host:port", store.remote("good") == "vpn.example.com:1194", store.remote("good") ?? "nil")
    let browser = browserProfiles(dataDir: dir + "/browser").map { "\($0.dir)=\($0.name)" }
    report("browser profiles are the folders, named by Local State", browser == ["Default=Me", "Profile 2=Work", "Profile 3=Profile 3"], "\(browser)")
    report("browser never launched has no profiles", browserProfiles(dataDir: dir + "/missing").isEmpty)
    return failed ? 1 : 0
}
