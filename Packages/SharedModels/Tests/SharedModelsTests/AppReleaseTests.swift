import XCTest
@testable import SharedModels

final class AppReleaseTests: XCTestCase {
  func test_versions_compareNumerically() throws {
    let v = { (s: String) in try XCTUnwrap(AppVersion(s)) }
    XCTAssertGreaterThan(try v("2.1.10"), try v("2.1.9"))
    XCTAssertGreaterThan(try v("v2.2"), try v("2.1.1"))
    XCTAssertEqual(try v("2.1"), try v("2.1.0"))
    XCTAssertEqual(try v("v2.1.1").description, "2.1.1")
    XCTAssertNil(AppVersion("2.1.1-beta"))
    XCTAssertNil(AppVersion("latest"))
  }

  /// The shape GitHub's `GET /repos/{owner}/{repo}/releases` returns.
  func test_decodesTheReleasesAPI() throws {
    let json = """
    [{"tag_name":"v2.1.1","body":"### Fixed\\n- A fix.","html_url":"https://github.com/vzts/aPhone-Mirroring/releases/tag/v2.1.1",
      "draft":false,"prerelease":false,
      "assets":[{"name":"aPhone-Mirroring-2.1.1.dmg","browser_download_url":"https://github.com/vzts/aPhone-Mirroring/releases/download/v2.1.1/aPhone-Mirroring-2.1.1.dmg"}]},
     {"tag_name":"v2.1.0","body":null,"html_url":"https://github.com/vzts/aPhone-Mirroring/releases/tag/v2.1.0","draft":false,"prerelease":false,"assets":[]}]
    """
    let releases = try JSONDecoder().decode([AppRelease].self, from: Data(json.utf8))
    XCTAssertEqual(releases.map(\.tag), ["v2.1.1", "v2.1.0"])
    XCTAssertEqual(releases[0].download?.lastPathComponent, "aPhone-Mirroring-2.1.1.dmg")
    XCTAssertNil(releases[1].download)
    XCTAssertEqual(releases[1].notes, "")
  }

  func test_newer_skipsDraftsAndPrereleases_newestFirst() throws {
    let page = URL(string: "https://example.com")!
    let releases = [
      AppRelease(tag: "v2.0.6", notes: "", page: page, download: nil),
      AppRelease(tag: "v2.1.1", notes: "", page: page, download: nil),
      AppRelease(tag: "v2.2.0", notes: "", page: page, download: nil, isDraft: true),
      AppRelease(tag: "v2.3.0", notes: "", page: page, download: nil, isPrerelease: true),
      AppRelease(tag: "v2.1.0", notes: "", page: page, download: nil),
      AppRelease(tag: "nightly", notes: "", page: page, download: nil),
    ]
    let newer = AppRelease.newer(than: try XCTUnwrap(AppVersion("2.0.6")), in: releases)
    XCTAssertEqual(newer.map(\.tag), ["v2.1.1", "v2.1.0"])
    XCTAssertTrue(AppRelease.newer(than: try XCTUnwrap(AppVersion("2.1.1")), in: releases).isEmpty)
  }

  /// The 2.1.0 release notes as published.
  func test_highlights_leaveOutInstallAndMarkdown() {
    let notes = """
    ### Added
    - **Phone notifications in Notification Center.** Turn on **Settings › General › Show phone notifications on this Mac**.

    ### Fixed
    * See [the README](https://github.com/vzts/aPhone-Mirroring#readme) for `adb`.

    ### Install
    Open the DMG and drag **aPhone Mirroring** to Applications.
    - Not a change.

    SHA-256: `abc`
    """
    let release = AppRelease(tag: "v2.1.0", notes: notes, page: URL(string: "https://example.com")!, download: nil)
    XCTAssertEqual(release.highlights, [
      "Phone notifications in Notification Center. Turn on Settings › General › Show phone notifications on this Mac.",
      "See the README for adb.",
    ])
  }

  func test_tagFromLatestRedirect() {
    XCTAssertEqual(AppRelease.tag(fromLatestPage: URL(string: "https://github.com/vzts/aPhone-Mirroring/releases/tag/v2.1.1")!), "v2.1.1")
    XCTAssertNil(AppRelease.tag(fromLatestPage: URL(string: "https://github.com/vzts/aPhone-Mirroring/releases")!))
  }
}
