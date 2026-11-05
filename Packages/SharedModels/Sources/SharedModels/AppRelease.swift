import Foundation

/// A dotted version, compared part by part: "2.1.10" is newer than "2.1.9".
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
  public let parts: [Int]

  /// "2.1.1" or a tag like "v2.1.1"; nil when it isn't numbers and dots.
  public init?(_ text: String) {
    var trimmed = Substring(text.trimmingCharacters(in: .whitespaces))
    if trimmed.first == "v" || trimmed.first == "V" { trimmed = trimmed.dropFirst() }
    let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
    self.parts = parts.compactMap { $0 }
  }

  public var description: String { parts.map(String.init).joined(separator: ".") }

  public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
    for i in 0..<max(lhs.parts.count, rhs.parts.count) {
      let l = i < lhs.parts.count ? lhs.parts[i] : 0
      let r = i < rhs.parts.count ? rhs.parts[i] : 0
      if l != r { return l < r }
    }
    return false
  }

  public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// One release as GitHub's releases API lists it.
public struct AppRelease: Sendable, Equatable, Decodable {
  public let tag: String
  public let notes: String
  public let page: URL
  /// The DMG, when the release has one.
  public let download: URL?
  public let isDraft: Bool
  public let isPrerelease: Bool

  public init(tag: String, notes: String, page: URL, download: URL?, isDraft: Bool = false, isPrerelease: Bool = false) {
    self.tag = tag
    self.notes = notes
    self.page = page
    self.download = download
    self.isDraft = isDraft
    self.isPrerelease = isPrerelease
  }

  public var version: AppVersion? { AppVersion(tag) }

  private enum CodingKeys: String, CodingKey {
    case tag = "tag_name", notes = "body", page = "html_url", isDraft = "draft", isPrerelease = "prerelease", assets
  }
  private struct Asset: Decodable {
    let name: String
    let browser_download_url: URL
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    tag = try c.decode(String.self, forKey: .tag)
    notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    page = try c.decode(URL.self, forKey: .page)
    isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
    isPrerelease = try c.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
    let assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    download = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })?.browser_download_url
  }

  /// What changed, one line per bullet: every section's bullets but
  /// Install's, with Markdown emphasis, code and links reduced to their text.
  public var highlights: [String] {
    var lines: [String] = []
    var inInstall = false
    for raw in notes.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("#") {
        inInstall = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased() == "install"
        continue
      }
      guard !inInstall, line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
      let text = Self.plainText(String(line.dropFirst(2)))
      if !text.isEmpty { lines.append(text) }
    }
    return lines
  }

  static func plainText(_ markdown: String) -> String {
    var text = markdown.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    for mark in ["**", "__", "`"] { text = text.replacingOccurrences(of: mark, with: "") }
    return text.trimmingCharacters(in: .whitespaces)
  }

  /// Published releases newer than `current`, newest first.
  public static func newer(than current: AppVersion, in releases: [AppRelease]) -> [AppRelease] {
    releases
      .filter { !$0.isDraft && !$0.isPrerelease }
      .compactMap { release in release.version.map { (release, $0) } }
      .filter { $0.1 > current }
      .sorted { $0.1 > $1.1 }
      .map(\.0)
  }

  /// `…/releases/latest` redirects to `…/releases/tag/<tag>`.
  public static func tag(fromLatestPage url: URL) -> String? {
    let parts = url.pathComponents
    guard let i = parts.lastIndex(of: "tag"), i + 1 < parts.count else { return nil }
    return parts[i + 1]
  }
}
