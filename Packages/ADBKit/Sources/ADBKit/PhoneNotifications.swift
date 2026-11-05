import Foundation

/// One notification on the phone, as `cmd notification get <key>` dumps it.
/// The shell may run `cmd notification list` and `get` (Android 11 and later);
/// `get` dumps the record unredacted, so title and text come through as typed.
public struct PhoneNotification: Sendable, Equatable {
  public let key: String
  public let packageName: String
  /// `NotificationManager.IMPORTANCE_*`: 3 (default) and up make a sound.
  public let importance: Int
  /// `Notification.flagsToString` names; older Android prints hex, which is
  /// mapped to the same names.
  public let flags: Set<String>
  public let title: String
  public let text: String
  /// Held back by the phone's Do Not Disturb.
  public let intercepted: Bool

  public init(key: String, packageName: String, importance: Int, flags: Set<String>,
              title: String, text: String, intercepted: Bool) {
    self.key = key
    self.packageName = packageName
    self.importance = importance
    self.flags = flags
    self.title = title
    self.text = text
    self.intercepted = intercepted
  }

  /// Something the phone itself would alert about — the kind worth showing
  /// on the Mac. Leaves out what sits in the shade without alerting (silent,
  /// ongoing, foreground-service, undismissable), group summaries (their
  /// children are shown instead), and notifications the app marked as not
  /// to be bridged to other devices.
  public var isAlerting: Bool {
    guard importance >= 3, !intercepted else { return false }
    guard flags.isDisjoint(with: Self.quietFlags) else { return false }
    return !(title.isEmpty && text.isEmpty)
  }

  static let quietFlags: Set<String> = [
    "ONGOING_EVENT", "NO_CLEAR", "FOREGROUND_SERVICE", "PROMOTED_ONGOING",
    "GROUP_SUMMARY", "AUTOGROUP_SUMMARY", "LOCAL_ONLY", "SILENT",
  ]
}

public enum PhoneNotificationParser {
  /// Separates records when several `get`s run in one shell call.
  public static let recordMarker = "@@APHONE-NOTIFICATION@@"
  /// Ends every command's output. Wireless adb can end a stream early without
  /// an error; a list cut short would read as notifications removed.
  public static let endMarker = "@@APHONE-END@@"

  /// One shell call that lists every notification's key with its last update
  /// time (`<key>\t  mUpdateTimeMs=<ms>`), so only new and changed ones need
  /// a full `get`.
  public static let signatureCommand =
    #"cmd notification list | while IFS= read -r k; do printf '%s\t%s\n' "$k" "$(cmd notification get "$k" | grep -m1 'mUpdateTimeMs=')"; done; echo @@APHONE-END@@"#

  /// One shell call that dumps the given notifications, each after `recordMarker`.
  public static func recordsCommand(keys: [String]) -> String {
    let quoted = keys.map { "'" + $0.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
    return "for k in \(quoted.joined(separator: " ")); do echo \(recordMarker); cmd notification get \"$k\"; done; echo \(endMarker)"
  }

  /// `signatureCommand` output → [key: last update time], or nil when the
  /// output is cut short or isn't a list (an error from `cmd`).
  public static func parseSignatures(_ text: String) -> [String: String]? {
    guard let end = text.range(of: endMarker) else { return nil }
    var result: [String: String] = [:]
    for line in text[..<end.lowerBound].components(separatedBy: "\n") {
      let row = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
      if row.isEmpty { continue }
      guard let tab = row.firstIndex(of: "\t") else { return nil }
      let key = String(row[..<tab])
      guard key.contains("|") else { continue }
      let rest = row[row.index(after: tab)...]
      if let marker = rest.range(of: "mUpdateTimeMs=") {
        result[key] = String(rest[marker.upperBound...].prefix(while: \.isNumber))
      } else {
        result[key] = ""  // gone between `list` and `get`, or no update time
      }
    }
    return result
  }

  /// `recordsCommand` output → notifications, in order, or nil when cut short.
  public static func parseRecords(_ text: String) -> [PhoneNotification]? {
    guard let end = text.range(of: endMarker) else { return nil }
    return text[..<end.lowerBound].components(separatedBy: recordMarker).compactMap(parseRecord)
  }

  /// `0|com.kakao.talk|7|null|10234` → `com.kakao.talk`.
  public static func packageName(ofKey key: String) -> String {
    let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
    return parts.count > 1 ? String(parts[1]) : ""
  }

  /// One `cmd notification get <key>` dump → notification.
  public static func parseRecord(_ dump: String) -> PhoneNotification? {
    let lines = dump.components(separatedBy: "\n").map {
      $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }
    guard let header = lines.first(where: { $0.contains("NotificationRecord(") }),
          let packageName = value(after: "pkg=", in: header, until: " "),
          let key = lines.lazy.compactMap({ field("key=", in: $0) }).first
    else { return nil }
    let importance = value(after: " importance=", in: header, until: " ").flatMap { Int($0) } ?? 0
    let flags = lines.lazy.compactMap({ field("flags=", in: $0) }).first.map(parseFlags) ?? []
    let intercepted = lines.contains { $0.trimmingCharacters(in: .whitespaces) == "mIntercept=true" }

    // The notification's own extras: the block under `notification=`, not
    // the one under `publicNotification=` (the lock-screen version).
    let start = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "notification=" } ?? lines.endIndex
    let end = lines[start...].firstIndex { $0.trimmingCharacters(in: .whitespaces) == "publicNotification=" } ?? lines.endIndex
    let extras = parseExtras(Array(lines[start..<end]))
    let title = extras["android.title"] ?? extras["android.conversationTitle"] ?? ""
    let text = extras["android.text"] ?? extras["android.bigText"] ?? ""
    return PhoneNotification(key: key, packageName: packageName, importance: importance, flags: flags,
                             title: title, text: text, intercepted: intercepted)
  }

  /// scrcpy server `list_apps=true` output → [package: label]. Each app is
  /// ` - Label<padding> package` (`*` for system apps); a label of 30 or more
  /// characters puts the package on the next line.
  public static func parseAppList(_ text: String) -> [String: String] {
    var labels: [String: String] = [:]
    var pendingLabel: String?
    for line in text.components(separatedBy: "\n") {
      let row = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
      if row.hasPrefix(" * ") || row.hasPrefix(" - ") {
        let entry = String(row.dropFirst(3))
        if let gap = entry.range(of: #"\s{2,}\S+$"#, options: .regularExpression) {
          let label = entry[..<gap.lowerBound].trimmingCharacters(in: .whitespaces)
          let package = entry[gap].trimmingCharacters(in: .whitespaces)
          labels[package] = label
          pendingLabel = nil
        } else {
          pendingLabel = entry.trimmingCharacters(in: .whitespaces)
        }
      } else if let label = pendingLabel {
        let package = row.trimmingCharacters(in: .whitespaces)
        if !package.isEmpty, !package.contains(" ") { labels[package] = label }
        pendingLabel = nil
      }
    }
    return labels
  }

  // MARK: pieces

  /// Older Android prints `flags=0x62`; newer prints `flags=ONGOING_EVENT|NO_CLEAR`.
  static func parseFlags(_ raw: String) -> Set<String> {
    if raw == "0" { return [] }
    if raw.hasPrefix("0x"), let bits = Int(raw.dropFirst(2), radix: 16) {
      return Set(flagBits.filter { bits & $0.bit != 0 }.map(\.name))
    }
    return Set(raw.split(separator: "|").map(String.init))
  }

  private static let flagBits: [(bit: Int, name: String)] = [
    (0x2, "ONGOING_EVENT"), (0x8, "ONLY_ALERT_ONCE"), (0x20, "NO_CLEAR"),
    (0x40, "FOREGROUND_SERVICE"), (0x100, "LOCAL_ONLY"), (0x200, "GROUP_SUMMARY"),
    (0x400, "AUTOGROUP_SUMMARY"),
  ]

  /// `extras={` entries are `<key>=<Class> (<value>)`, one per line at the
  /// block's indent + 4; a value with newlines runs on over unindented lines.
  static func parseExtras(_ lines: [String]) -> [String: String] {
    guard let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "extras={" }) else { return [:] }
    let indent = String(lines[open].prefix(while: { $0 == " " }))
    let entryIndent = indent + "    "
    var entries: [(key: String, raw: String)] = []
    for line in lines[(open + 1)...] {
      if line == indent + "}" { break }
      if line.hasPrefix(entryIndent), line.dropFirst(entryIndent.count).first != " ",
         let eq = line.firstIndex(of: "=") {
        let key = String(line[line.index(line.startIndex, offsetBy: entryIndent.count)..<eq])
        entries.append((key, String(line[line.index(after: eq)...])))
      } else if !entries.isEmpty {
        entries[entries.count - 1].raw += "\n" + line
      }
    }
    var result: [String: String] = [:]
    for entry in entries {
      // `String (text)`, `SpannableString (text)`, … or `null`.
      guard let open = entry.raw.range(of: " ("), entry.raw.hasSuffix(")") else { continue }
      result[entry.key] = String(entry.raw[open.upperBound...].dropLast())
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return result
  }

  /// `  name=value` on a line of its own → value.
  private static func field(_ name: String, in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix(name) else { return nil }
    return String(trimmed.dropFirst(name.count))
  }

  private static func value(after marker: String, in line: String, until end: Character) -> String? {
    guard let range = line.range(of: marker) else { return nil }
    let value = line[range.upperBound...].prefix(while: { $0 != end })
    return value.isEmpty ? nil : String(value)
  }
}
