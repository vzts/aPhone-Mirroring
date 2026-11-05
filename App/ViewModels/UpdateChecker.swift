import AppKit
import SharedModels
import SwiftUI
import os

private let log = Logger(subsystem: "io.github.vzts.aphonemirroring", category: "updates")

/// Tells the user when a newer release is on GitHub, the way Sparkle-based
/// Mac apps do:
/// - automatic checks are asked for on the second launch, not assumed, and
///   can be turned off in Settings › Advanced;
/// - they run once a day — at launch when a day has passed, and while the
///   app stays open;
/// - a scheduled check never takes focus: its alert waits until the user is
///   in the app, and the menu bar menu offers the update meanwhile;
/// - Remind Me Later brings it back at the next daily check, Skip This
///   Version for good; Check for Updates… always answers.
///
/// There's no update server: GitHub's releases API gives each release's
/// version and notes (60 requests an hour without a token), and the
/// releases/latest page, which redirects to the newest tag, stands in when
/// the API can't be reached. Nothing is installed for the user: Download
/// opens the DMG (the app isn't notarized, so a silent install couldn't open).
@MainActor
final class UpdateChecker: ObservableObject {
  static let shared = UpdateChecker()
  /// Bool; absent until the user has been asked.
  static let automaticKey = "updates.automaticChecks"
  private static let launchesKey = "updates.launches"
  private static let lastCheckKey = "updates.lastCheck"
  private static let skippedKey = "updates.skippedVersion"
  private static let interval: TimeInterval = 24 * 60 * 60
  private static let releasesAPI = URL(string: "https://api.github.com/repos/vzts/aPhone-Mirroring/releases?per_page=20")!

  enum State {
    case idle
    case checking
    case upToDate
    case available([AppRelease])
    case failed
  }

  /// What the Software Update window shows.
  enum Panel { case permission, result }

  @Published private(set) var state: State = .idle
  @Published private(set) var panel: Panel = .result
  /// A newer release the user hasn't skipped; the menu bar menu offers it.
  @Published private(set) var pending: AppRelease?
  @Published private(set) var lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date

  private var window: NSWindow?
  private var dailyTimer: Timer?
  /// A scheduled check found an update while the user was in another app.
  private var alertWhenActive = false

  /// This build's version.
  let current: AppVersion = {
    #if DEBUG
    // Lets a debug build pretend to be older to see the update window.
    if let pretend = ProcessInfo.processInfo.environment["APHONE_PRETEND_VERSION"], let v = AppVersion(pretend) { return v }
    #endif
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    return short.flatMap(AppVersion.init) ?? AppVersion("0")!
  }()

  var automaticChecks: Bool? {
    UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool
  }

  private init() {
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.alertWhenActive else { return }
        self.alertWhenActive = false
        self.showWindow(activate: false)
      }
    }
  }

  // MARK: launch and schedule

  func appLaunched() {
    let launches = UserDefaults.standard.integer(forKey: Self.launchesKey) + 1
    UserDefaults.standard.set(launches, forKey: Self.launchesKey)
    guard automaticChecks != nil else {
      // The first launch is for trying the app; ask on the next one.
      if launches >= 2 {
        Task {
          try? await Task.sleep(for: .seconds(3))
          guard self.automaticChecks == nil else { return }
          self.panel = .permission
          self.showWindow(activate: false)
        }
      }
      return
    }
    schedule()
  }

  /// The setting changed (the prompt or Settings › Advanced).
  func setAutomaticChecks(_ on: Bool) {
    UserDefaults.standard.set(on, forKey: Self.automaticKey)
    log.notice("automatic update checks \(on ? "on" : "off", privacy: .public)")
    schedule()
  }

  private func schedule() {
    dailyTimer?.invalidate()
    dailyTimer = nil
    guard automaticChecks == true else { return }
    Task {
      // Phones connect and mirror first; this can wait a moment.
      try? await Task.sleep(for: .seconds(3))
      await scheduledCheck()
    }
    // Hourly look, daily check: an app left open still hears about updates.
    dailyTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
      Task { @MainActor in await UpdateChecker.shared.scheduledCheck() }
    }
  }

  private func scheduledCheck() async {
    guard automaticChecks == true else { return }
    if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
    await check()
    guard let pending else { return }
    log.notice("scheduled check found \(pending.tag, privacy: .public)")
    panel = .result
    // Never take focus from another app: wait until the user is in this one.
    if NSApp.isActive { showWindow(activate: false) } else { alertWhenActive = true }
  }

  // MARK: actions

  /// Check for Updates…: always checks, always answers.
  func checkNow() {
    panel = .result
    state = .checking
    showWindow(activate: true)
    Task { await check(ignoringSkipped: true) }
  }

  func allowAutomaticChecks(_ allow: Bool) {
    setAutomaticChecks(allow)
    closeWindow()
  }

  func download() {
    guard case .available(let releases) = state, let newest = releases.first else { return }
    NSWorkspace.shared.open(newest.download ?? newest.page)
    closeWindow()
  }

  /// Comes back at the next daily check; the menu keeps offering it meanwhile.
  func remindLater() { closeWindow() }

  func skipThisVersion() {
    if case .available(let releases) = state, let newest = releases.first?.version {
      UserDefaults.standard.set(newest.description, forKey: Self.skippedKey)
    }
    pending = nil
    closeWindow()
  }

  /// The menu bar menu's "Update to …" item.
  func showPending() {
    guard let pending else { return }
    panel = .result
    state = .available(availableReleases ?? [pending])
    showWindow(activate: true)
  }

  func openReleasesPage() {
    NSWorkspace.shared.open(AppInfo.repository.appendingPathComponent("releases"))
    closeWindow()
  }

  func closeWindow() { window?.close() }

  // MARK: checking

  /// The last list of newer releases, kept for the menu's "Update to …".
  private var availableReleases: [AppRelease]?

  private func check(ignoringSkipped: Bool = false) async {
    state = .checking
    if let releases = await fetchReleases() {
      let newer = AppRelease.newer(than: current, in: releases)
      state = newer.isEmpty ? .upToDate : .available(newer)
    } else if let tag = await latestTagFromPage(), let latest = AppVersion(tag) {
      // Version only; the window links to the release notes instead.
      let page = AppInfo.repository.appendingPathComponent("releases/tag/\(tag)")
      state = latest > current ? .available([AppRelease(tag: tag, notes: "", page: page, download: nil)]) : .upToDate
    } else {
      state = .failed
    }
    if case .failed = state {} else {
      lastCheck = Date()
      UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
    }
    switch state {
    case .available(let releases):
      availableReleases = releases
      let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
      let newest = releases.first
      pending = ignoringSkipped || newest?.version?.description != skipped ? newest : nil
      log.notice("update available: \(newest?.tag ?? "", privacy: .public) (\(releases.count) newer than \(self.current.description, privacy: .public))")
    case .upToDate:
      availableReleases = nil
      pending = nil
      log.notice("up to date at \(self.current.description, privacy: .public)")
    case .failed:
      log.notice("couldn't check for updates")
    case .idle, .checking:
      break
    }
  }

  private func fetchReleases() async -> [AppRelease]? {
    var request = URLRequest(url: Self.releasesAPI, timeoutInterval: 10)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("aPhoneMirroring/\(current)", forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return try? JSONDecoder().decode([AppRelease].self, from: data)
  }

  /// `releases/latest` redirects to the newest release's tag page.
  private func latestTagFromPage() async -> String? {
    var request = URLRequest(url: AppInfo.repository.appendingPathComponent("releases/latest"), timeoutInterval: 10)
    request.httpMethod = "HEAD"
    guard let (_, response) = try? await URLSession.shared.data(for: request), let url = response.url else { return nil }
    return AppRelease.tag(fromLatestPage: url)
  }

  // MARK: window

  /// `activate`: only for what the user asked for. Scheduled alerts and the
  /// permission prompt appear without pulling the app in front.
  private func showWindow(activate: Bool) {
    if window == nil {
      log.notice("showing the Software Update window (\(self.panel == .permission ? "permission" : "result", privacy: .public))")
      let hosting = NSHostingController(rootView: UpdateView(checker: self))
      let window = NSWindow(contentViewController: hosting)
      window.title = String(localized: "Software Update")
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      window.center()
      NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.window = nil }
      }
      self.window = window
    }
    if activate {
      window?.makeKeyAndOrderFront(nil)
      NSApp.activate()
    } else {
      window?.orderFront(nil)
    }
  }
}
