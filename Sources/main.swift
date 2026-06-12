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
let configPath: String = {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["PROFILELAUNCHER_CONFIG"], !env.isEmpty {
        return NSString(string: env).expandingTildeInPath
    }
    let xdg = NSString(string: "~/.config/profilelauncher/rules.json").expandingTildeInPath
    if fm.fileExists(atPath: xdg) { return xdg }
    return NSString(string: "~/Library/Application Support/ProfileLauncher/rules.json").expandingTildeInPath
}()

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

func loadConfig() -> Config {
    guard let data = FileManager.default.contents(atPath: configPath) else {
        log("No config at \(configPath); using empty ruleset")
        return Config(bravePath: nil, rules: [], fallbackProfile: nil)
    }
    do {
        return try JSONDecoder().decode(Config.self, from: data)
    } catch {
        log("Config parse error: \(error). Using empty ruleset.")
        return Config(bravePath: nil, rules: [], fallbackProfile: nil)
    }
}

// MARK: - Profile resolution (display name -> directory name)

func resolveProfileDirectory(_ value: String) -> String {
    // If it's already a directory that exists, use as-is.
    let dir = (braveSupportDir as NSString).appendingPathComponent(value)
    if FileManager.default.fileExists(atPath: dir) { return value }

    // Otherwise try to match a display name in Local State's info_cache.
    let localState = (braveSupportDir as NSString).appendingPathComponent("Local State")
    if let data = FileManager.default.contents(atPath: localState),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let profile = json["profile"] as? [String: Any],
       let cache = profile["info_cache"] as? [String: Any] {
        for (dirName, info) in cache {
            if let info = info as? [String: Any],
               let name = info["name"] as? String,
               name == value {
                return dirName
            }
        }
    }
    log("Could not resolve profile '\(value)'; passing through to Brave")
    return value
}

// MARK: - Become the default browser

func setAsDefaultBrowser() {
    let id = (Bundle.main.bundleIdentifier ?? "com.local.profilelauncher") as CFString
    // macOS shows a confirmation dialog the first time a new app requests this.
    let httpResult = LSSetDefaultHandlerForURLScheme("http" as CFString, id)
    let httpsResult = LSSetDefaultHandlerForURLScheme("https" as CFString, id)
    let http = LSCopyDefaultHandlerForURLScheme("http" as CFString)?.takeRetainedValue() as String?
    let https = LSCopyDefaultHandlerForURLScheme("https" as CFString)?.takeRetainedValue() as String?
    print("Requested default browser = \(id)")
    print("  http  set=\(httpResult) now=\(http ?? "nil")")
    print("  https set=\(httpsResult) now=\(https ?? "nil")")
    if http == (id as String) && https == (id as String) {
        print("OK: ProfileLauncher is now the default web browser.")
    } else {
        print("If unchanged, confirm the macOS dialog, or set it in")
        print("System Settings > Desktop & Dock > Default web browser.")
    }
}

// MARK: - Profile listing (for setting up a new machine)

func listProfiles() {
    print("Brave profiles on this machine (\(braveSupportDir)):\n")
    let localState = (braveSupportDir as NSString).appendingPathComponent("Local State")
    guard let data = FileManager.default.contents(atPath: localState),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let profile = json["profile"] as? [String: Any],
          let cache = profile["info_cache"] as? [String: Any] else {
        print("  (could not read Local State — is Brave installed?)")
        return
    }
    func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }
    print("  " + pad("DIRECTORY", 14) + "DISPLAY NAME")
    for (dirName, info) in cache.sorted(by: { $0.key < $1.key }) {
        let name = (info as? [String: Any])?["name"] as? String ?? "?"
        print("  " + pad(dirName, 14) + name)
    }
    print("\nIn rules.json you may use either the directory or the display name as \"profile\".")
    print("Config file in use: \(configPath)")
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
        let dir = resolveProfileDirectory(profileValue)
        args.append("--profile-directory=\(dir)")
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

// CLI: `ProfileLauncher --list-profiles` shows available Brave profiles on this machine.
if CommandLine.arguments.dropFirst().contains("--list-profiles") {
    listProfiles()
    exit(0)
}

// CLI: `ProfileLauncher --set-default` registers itself as the default web browser.
if CommandLine.arguments.dropFirst().contains("--set-default") {
    setAsDefaultBrowser()
    exit(0)
}

// Support a CLI test mode: `ProfileLauncher https://example.com`
let cliURLs = CommandLine.arguments.dropFirst().compactMap { URL(string: $0) }
if !cliURLs.isEmpty {
    let config = loadConfig()
    for url in cliURLs { openInBrave(url: url, config: config) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar
app.run()
