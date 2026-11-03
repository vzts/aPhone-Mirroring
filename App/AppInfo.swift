import Foundation

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

