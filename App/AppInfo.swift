import AppKit

enum AppInfo {
  /// Localized display name ("aPhone Mirroring", "aPhone 미러링", …).
  static var name: String {
    (Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
      ?? (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
      ?? "aPhone Mirroring"
  }

  static let repository = URL(string: "https://github.com/vzts/aPhone-Mirroring")!

  /// This app used to ship as Droid Mirroring under another bundle id. Carry
  /// over trusted phones, window placement, and settings once, so updating
  /// doesn't feel like a fresh install. (Pairing lives in adb and survives.)
  static func migrateSettingsFromDroidMirroring() {
    let defaults = UserDefaults.standard
    let doneKey = "migratedFromDroidMirroring"
    guard !defaults.bool(forKey: doneKey) else { return }
    defaults.set(true, forKey: doneKey)
    guard let old = UserDefaults(suiteName: "com.droidmirroring.app.DroidMirroring") else { return }
    let keep = ["mirror.", "settings.", "showMenuBarIcon"]
    for (key, value) in old.dictionaryRepresentation()
    where keep.contains(where: key.hasPrefix) && defaults.object(forKey: key) == nil {
      defaults.set(value, forKey: key)
    }
  }
}

/// App UI language. `nil` follows the system's preferred languages.
enum AppLanguage {
  struct Language { let code: String; let name: String }

  /// Shown in their own language, as macOS does.
  static let supported: [Language] = [
    .init(code: "en", name: "English"),
    .init(code: "ko", name: "한국어"),
    .init(code: "ja", name: "日本語"),
    .init(code: "zh-Hans", name: "简体中文"),
    .init(code: "zh-Hant", name: "繁體中文"),
    .init(code: "es", name: "Español"),
    .init(code: "fr", name: "Français"),
    .init(code: "de", name: "Deutsch"),
    .init(code: "pt-BR", name: "Português (Brasil)"),
    .init(code: "ru", name: "Русский"),
    .init(code: "it", name: "Italiano"),
  ]

  /// The override this process launched with — what the UI is showing now.
  /// Captured once at launch; `override` itself changes as soon as the user
  /// picks another language.
  private(set) static var atLaunch: String?

  static func captureLaunchState() { atLaunch = override }

  /// Per-app `AppleLanguages`, read from this app's own domain so the system
  /// list never shows up as an "override".
  static var override: String? {
    get {
      let domain = Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:))
      return (domain?["AppleLanguages"] as? [String])?.first
    }
    set {
      if let newValue { UserDefaults.standard.set([newValue], forKey: "AppleLanguages") }
      else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
    }
  }

  /// Quit (letting sessions clean up) and open again in the new language.
  /// The helper waits for this process to be gone first; opening while it is
  /// still quitting would just re-activate it.
  static func relaunch() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = [
      "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
      Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier),
    ]
    try? task.run()
    // Via a run-loop timer, not inline: terminate's NSTerminateLater cleanup
    // runs on the main queue, which is stuck if we're already inside a
    // main-queue block (a Task or async callback) — the app would never quit.
    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
  }
}
