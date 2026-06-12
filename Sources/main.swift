import AppKit
import CoreServices
import Foundation

// MARK: - Config models

struct Rule: Decodable {
    let match: String        // host glob, e.g. "github.com" or "*.work.com" or "*example*"
    let profile: String      // Brave profile: directory ("Profile 1") or display name ("sub")
}

struct Config: Decodable {
    let bravePath: String?
    let rules: [Rule]
    let fallbackProfile: String?   // nil = let Brave decide (front profile)
}

// MARK: - Paths

let defaultBravePath = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
let braveSupportDir = NSString(string: "~/Library/Application Support/BraveSoftware/Brave-Browser").expandingTildeInPath

// Config location, resolved in priority order so it is portable across machines:
//   1. $PROFILELAUNCHER_CONFIG  (point this at a dotfiles / cloud-synced file)
//   2. ~/.config/profilelauncher/rules.json  (XDG-style, easy to put under version control)
//   3. ~/Library/Application Support/ProfileLauncher/rules.json  (default)
let xdgConfigPath = NSString(string: "~/.config/profilelauncher/rules.json").expandingTildeInPath
let appSupportConfigPath = NSString(string: "~/Library/Application Support/ProfileLauncher/rules.json").expandingTildeInPath

let configPath: String = {
    if let env = ProcessInfo.processInfo.environment["PROFILELAUNCHER_CONFIG"], !env.isEmpty {
        return NSString(string: env).expandingTildeInPath
    }
    if FileManager.default.fileExists(atPath: xdgConfigPath) { return xdgConfigPath }
    return appSupportConfigPath
}()

// Other config files that exist but are being IGNORED because something
// higher-priority won. Used to warn about "I edited the wrong file".
func shadowedConfigPaths() -> [String] {
    let fm = FileManager.default
    var candidates: [String] = []
    if ProcessInfo.processInfo.environment["PROFILELAUNCHER_CONFIG"] != nil {
        candidates = [xdgConfigPath, appSupportConfigPath]
    } else if configPath == xdgConfigPath {
        candidates = [appSupportConfigPath]
    }
    return candidates.filter { $0 != configPath && fm.fileExists(atPath: $0) }
}

// MARK: - Logging (to ~/Library/Logs/ProfileLauncher.log)

let logPath = NSString(string: "~/Library/Logs/ProfileLauncher.log").expandingTildeInPath
func log(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Config loading

enum ConfigLoad {
    case ok(Config)
    case missing
    case parseError(String)
}

// Read and parse the config, distinguishing missing vs malformed so the
// diagnostics commands can report a malformed file loudly instead of
// silently degrading to an empty ruleset.
func readConfig() -> ConfigLoad {
    guard let data = FileManager.default.contents(atPath: configPath) else {
        return .missing
    }
    if data.isEmpty { return .parseError("file is empty") }
    do {
        return .ok(try JSONDecoder().decode(Config.self, from: data))
    } catch let DecodingError.dataCorrupted(ctx) {
        return .parseError("invalid JSON — \(ctx.debugDescription)")
    } catch let DecodingError.keyNotFound(key, _) {
        return .parseError("missing required key \"\(key.stringValue)\"")
    } catch let DecodingError.typeMismatch(_, ctx) {
        let path = ctx.codingPath.map { $0.stringValue }.joined(separator: ".")
        return .parseError("wrong type at \"\(path)\" — \(ctx.debugDescription)")
    } catch {
        return .parseError("\(error)")
    }
}

func loadConfig() -> Config {
    switch readConfig() {
    case .ok(let config):
        return config
    case .missing:
        log("No config at \(configPath); using empty ruleset")
        return Config(bravePath: nil, rules: [], fallbackProfile: nil)
    case .parseError(let msg):
        log("Config parse error: \(msg). Using empty ruleset — NO URLS WILL BE ROUTED.")
        return Config(bravePath: nil, rules: [], fallbackProfile: nil)
    }
}

// MARK: - Profile discovery

struct BraveProfile {
    let directory: String   // e.g. "Profile 1"
    let name: String        // display name, e.g. "sub"
}

// Read all Brave profiles on this machine from Local State (info_cache).
func allProfiles() -> [BraveProfile] {
    let localState = (braveSupportDir as NSString).appendingPathComponent("Local State")
    guard let data = FileManager.default.contents(atPath: localState),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let profile = json["profile"] as? [String: Any],
          let cache = profile["info_cache"] as? [String: Any] else {
        return []
    }
    return cache.compactMap { (dir, info) in
        let name = (info as? [String: Any])?["name"] as? String ?? dir
        return BraveProfile(directory: dir, name: name)
    }.sorted { $0.directory < $1.directory }
}

// MARK: - Profile resolution (rule value -> directory name)

// Resolve a rule's "profile" value to an actual profile directory on this
// machine. Accepts either a directory name ("Profile 1") or a display name
// ("sub"), case-insensitively. Returns nil if no such profile exists here.
func resolveProfileDirectory(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let profiles = allProfiles()

    // Exact directory match.
    if let p = profiles.first(where: { $0.directory == trimmed }) { return p.directory }
    // Exact display-name match.
    if let p = profiles.first(where: { $0.name == trimmed }) { return p.directory }
    // Case-insensitive fallback (directory then display name).
    let lower = trimmed.lowercased()
    if let p = profiles.first(where: { $0.directory.lowercased() == lower }) { return p.directory }
    if let p = profiles.first(where: { $0.name.lowercased() == lower }) { return p.directory }

    return nil
}

// MARK: - Become the default browser

// Read the current default handler's bundle id via the non-deprecated
// NSWorkspace API (LSCopyDefaultHandlerForURLScheme is deprecated).
func currentDefaultBundleID(forScheme scheme: String) -> String? {
    guard let url = URL(string: "\(scheme)://example.com"),
          let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
    return Bundle(url: appURL)?.bundleIdentifier
}

// Path of whichever app currently handles http, for human-readable diagnosis.
func currentDefaultAppPath(forScheme scheme: String) -> String? {
    guard let url = URL(string: "\(scheme)://example.com") else { return nil }
    return NSWorkspace.shared.urlForApplication(toOpen: url)?.path
}

// MARK: - Diagnostics

// One-shot health check for "it works here but not on another machine".
// Prints PASS/FAIL for each prerequisite so the cause is obvious.
func doctor() {
    let myID = Bundle.main.bundleIdentifier ?? "com.local.profilelauncher"
    func line(_ ok: Bool, _ label: String, _ detail: String) {
        print("  [\(ok ? "PASS" : "FAIL")] \(label): \(detail)")
    }

    print("ProfileLauncher doctor\n")
    print("  app bundle id : \(myID)")
    print("  app path      : \(Bundle.main.bundlePath)\n")

    // 1) Are we the default browser? This is the #1 reason links don't reach us.
    let httpID = currentDefaultBundleID(forScheme: "http")
    let httpsID = currentDefaultBundleID(forScheme: "https")
    let isDefault = (httpID == myID && httpsID == myID)
    line(isDefault, "default browser",
         isDefault ? "ProfileLauncher handles http+https"
                   : "http=\(httpID ?? "nil") (\(currentDefaultAppPath(forScheme: "http") ?? "?")), https=\(httpsID ?? "nil") — links go HERE, not to ProfileLauncher")
    if !isDefault {
        print("         fix: run with --set-default, or System Settings > Desktop & Dock > Default web browser")
    }

    // 2) Does the configured Brave executable exist on THIS machine?
    let config = loadConfig()
    let bravePath = config.bravePath ?? defaultBravePath
    let braveOK = FileManager.default.isExecutableFile(atPath: bravePath)
    line(braveOK, "Brave executable", braveOK ? bravePath : "NOT FOUND/!executable: \(bravePath)")
    if !braveOK {
        print("         fix: set \"bravePath\" in rules.json to this machine's Brave binary")
    }

    // 3) Config file present AND valid JSON? A malformed file silently
    //    degrades to 0 rules, so call it out explicitly.
    switch readConfig() {
    case .ok:
        line(true, "config file", configPath)
    case .missing:
        line(false, "config file", "missing: \(configPath)")
        print("         fix: create it (copy rules.example.json) — see --check / --list-profiles")
    case .parseError(let msg):
        line(false, "config file", "\(configPath)\n         PARSE ERROR: \(msg)")
        print("         => rules.json is not valid JSON, so 0 rules load and nothing is routed.")
        print("         fix: correct the JSON (run --check after), or recopy rules.example.json")
    }
    for ignored in shadowedConfigPaths() {
        print("  [WARN] another config exists but is IGNORED: \(ignored)")
        print("         (the active config above wins — edit the active one, not this)")
    }
    let profiles = allProfiles()
    line(!profiles.isEmpty, "brave profiles",
         profiles.isEmpty ? "none found under \(braveSupportDir) — wrong support dir?"
                          : "\(profiles.count) found: " + profiles.map { "\($0.directory)=\"\($0.name)\"" }.joined(separator: ", "))
    line(!config.rules.isEmpty, "rules", "\(config.rules.count) rule(s)")

    // 4) Recent activity — empty after clicking a link means we are never invoked.
    print("\n  recent log (\(logPath)):")
    if let content = try? String(contentsOfFile: logPath, encoding: .utf8) {
        let lines = content.split(separator: "\n").suffix(8)
        if lines.isEmpty { print("    (log file is empty)") }
        for l in lines { print("    \(l)") }
    } else {
        print("    (no log yet — the app has not handled any URL)")
    }

    print("\n  How to test routing:")
    print("    1) click a link (or run: open https://github.com)")
    print("    2) run --doctor again; if 'recent log' did not grow, ProfileLauncher")
    print("       is not the default browser (see the default browser check above).")
}

func setAsDefaultBrowser() {
    let idString = Bundle.main.bundleIdentifier ?? "com.local.profilelauncher"
    let id = idString as CFString
    // macOS shows a confirmation dialog the first time a new app requests this.
    let httpResult = LSSetDefaultHandlerForURLScheme("http" as CFString, id)
    let httpsResult = LSSetDefaultHandlerForURLScheme("https" as CFString, id)
    let http = currentDefaultBundleID(forScheme: "http")
    let https = currentDefaultBundleID(forScheme: "https")
    print("Requested default browser = \(idString)")
    print("  http  set=\(httpResult) now=\(http ?? "nil")")
    print("  https set=\(httpsResult) now=\(https ?? "nil")")
    if http == idString && https == idString {
        print("OK: ProfileLauncher is now the default web browser.")
    } else {
        print("If unchanged, confirm the macOS dialog, or set it in")
        print("System Settings > Desktop & Dock > Default web browser.")
    }
}

// MARK: - Profile listing (for setting up a new machine)

func pad(_ s: String, _ w: Int) -> String {
    // Pad by display width (CJK names like "就活" are wide).
    let width = s.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
    return width >= w ? s : s + String(repeating: " ", count: w - width)
}

func listProfiles() {
    print("Brave profiles on this machine (\(braveSupportDir)):\n")
    let profiles = allProfiles()
    if profiles.isEmpty {
        print("  (could not read Local State — is Brave installed at the expected path?)")
        return
    }
    print("  " + pad("DIRECTORY", 14) + "DISPLAY NAME")
    for p in profiles {
        print("  " + pad(p.directory, 14) + p.name)
    }
    print("\nIn rules.json you may use either the directory or the display name as \"profile\".")
    print("Config file in use: \(configPath)")
}

// Validate rules.json against the profiles actually present on this machine.
func checkConfig() {
    print("Config file: \(configPath)")
    for ignored in shadowedConfigPaths() {
        print("  WARNING: ignored config also present: \(ignored) (edit the active one above)")
    }
    print("Brave dir:   \(braveSupportDir)\n")

    // Bail out loudly if the file is missing or malformed — otherwise the
    // report below would misleadingly show "no rules defined".
    switch readConfig() {
    case .missing:
        print("ERROR: config file does not exist.")
        print("Create it (copy rules.example.json) then re-run --check.")
        return
    case .parseError(let msg):
        print("ERROR: cannot load rules.json — \(msg)")
        print("Fix the JSON, then re-run --check. (Until fixed, 0 rules load and nothing is routed.)")
        return
    case .ok:
        break
    }

    let config = loadConfig()
    let profiles = allProfiles()

    print("Profiles on this machine:")
    if profiles.isEmpty {
        print("  (none found — is Brave installed at the expected path?)")
    } else {
        print("  " + pad("DIRECTORY", 14) + "DISPLAY NAME")
        for p in profiles { print("  " + pad(p.directory, 14) + p.name) }
    }

    print("\nRules:")
    if config.rules.isEmpty { print("  (no rules defined)") }
    var problems = 0
    for (i, rule) in config.rules.enumerated() {
        if let dir = resolveProfileDirectory(rule.profile) {
            print("  [\(i)] ok  \(pad(rule.match, 22)) -> \(rule.profile)  (uses \(dir))")
        } else {
            problems += 1
            print("  [\(i)] ERR \(pad(rule.match, 22)) -> \(rule.profile)  (NO SUCH PROFILE here)")
        }
    }

    if let fb = config.fallbackProfile {
        if let dir = resolveProfileDirectory(fb) {
            print("\nfallbackProfile: \(fb)  (uses \(dir))")
        } else {
            problems += 1
            print("\nfallbackProfile: \(fb)  (NO SUCH PROFILE here)")
        }
    } else {
        print("\nfallbackProfile: none (unmatched URLs open in Brave's front profile)")
    }

    print("")
    if problems == 0 {
        print("All referenced profiles exist on this machine. ✓")
    } else {
        print("\(problems) reference(s) do not match any profile here.")
        print("Fix the \"profile\" values above to one of the DIRECTORY or DISPLAY NAME values listed.")
    }
}

// MARK: - Matching

func glob(_ pattern: String, matches text: String) -> Bool {
    // Convert a simple glob (only `*` is special) to a regex anchored fully.
    let escaped = NSRegularExpression.escapedPattern(for: pattern)
        .replacingOccurrences(of: "\\*", with: ".*")
    guard let re = try? NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive]) else {
        return false
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return re.firstMatch(in: text, options: [], range: range) != nil
}

func profileFor(url: URL, config: Config) -> String? {
    let host = url.host ?? ""
    for rule in config.rules {
        // Match against host first; if the pattern contains a slash, match full URL.
        let target = rule.match.contains("/") ? url.absoluteString : host
        if glob(rule.match, matches: target) {
            log("URL \(url.absoluteString) matched rule '\(rule.match)' -> \(rule.profile)")
            return rule.profile
        }
    }
    log("URL \(url.absoluteString) matched no rule; fallback=\(config.fallbackProfile ?? "none")")
    return config.fallbackProfile
}

// MARK: - Launch

func openInBrave(url: URL, config: Config) {
    let bravePath = config.bravePath ?? defaultBravePath
    var args: [String] = []
    if let profileValue = profileFor(url: url, config: config) {
        if let dir = resolveProfileDirectory(profileValue) {
            args.append("--profile-directory=\(dir)")
        } else {
            // The configured profile does not exist on this machine. Do NOT pass
            // it to Brave — that would create a junk empty profile. Fall back to
            // Brave's current (front) profile and log the valid names.
            let available = allProfiles()
                .map { "\($0.directory)=\"\($0.name)\"" }
                .joined(separator: ", ")
            log("Profile '\(profileValue)' not found on this machine; opening in Brave's front profile instead. Available: [\(available)]")
        }
    }
    args.append(url.absoluteString)

    let task = Process()
    task.executableURL = URL(fileURLWithPath: bravePath)
    task.arguments = args
    do {
        try task.run()
        log("Launched: \(bravePath) \(args.joined(separator: " "))")
    } catch {
        log("Launch failed: \(error)")
    }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else {
            log("Received URL event without usable URL")
            return
        }
        // Reload config on every event so edits to rules.json take effect
        // immediately, with no app restart (effectively a hot reload).
        openInBrave(url: url, config: loadConfig())
    }
}

// MARK: - Entry point

func usage() {
    print("""
    ProfileLauncher — route URLs to Brave profiles.

    Usage:
      ProfileLauncher                 run as the default-browser agent (no args)
      ProfileLauncher --list-profiles list this machine's Brave profiles
      ProfileLauncher --check         validate rules.json against this machine
      ProfileLauncher --doctor        full health check (default browser, Brave, config, log)
      ProfileLauncher --set-default   register as the default web browser
      ProfileLauncher --help          show this help
      ProfileLauncher <url> [url...]  open the given http(s) URL(s) via the rules
    """)
}

let cliArgs = Array(CommandLine.arguments.dropFirst())

switch cliArgs.first {
case .none:
    // No arguments: run as the background default-browser agent.
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon, no menu bar
    app.run()

case "--help", "-h":
    usage()
    exit(0)

case "--list-profiles":
    listProfiles()
    exit(0)

case "--doctor":
    doctor()
    exit(0)

case "--check":
    checkConfig()
    exit(0)

case "--set-default":
    setAsDefaultBrowser()
    exit(0)

case .some(let first) where first.hasPrefix("-"):
    // Unknown flag. Never fall through to "open as URL" — that used to launch
    // Brave with the flag text and confused users on older builds.
    FileHandle.standardError.write(Data("Unknown option: \(first)\n".utf8))
    usage()
    exit(2)

default:
    // Treat arguments as URLs, but only real web URLs (must have a scheme).
    // This rejects things like "--check" on a version mismatch.
    let config = loadConfig()
    var opened = 0
    for arg in cliArgs {
        guard let url = URL(string: arg), let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()) else {
            FileHandle.standardError.write(Data("Ignoring non-URL argument: \(arg)\n".utf8))
            continue
        }
        openInBrave(url: url, config: config)
        opened += 1
    }
    exit(opened > 0 ? 0 : 2)
}
