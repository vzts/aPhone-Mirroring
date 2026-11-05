import AppKit
import SharedModels
import SwiftUI
import os

private let log = Logger(subsystem: "io.github.vzts.aphonemirroring", category: "updates")

/// Tells the user when a newer release is out, and stays quiet otherwise.
///
/// The check runs on its own — shortly after launch when a day has passed,
/// and daily while the app stays open — and shows nothing unless there's a
/// new version. Then a window says what changed, with a "Don't tell me about
/// new versions" box to stop these notices (Settings › Advanced › Automatically
/// check for updates turns them back on). A
/// check never takes focus: its window waits until the user is in the app,
/// and the menu bar menu offers the update meanwhile. Check for Updates…
/// always answers, including "You're up to date!".
///
/// There's no update server: GitHub's releases API gives each release's
/// version and notes, and when it can't be reached the releases/latest page,
/// which redirects to the newest tag, still gives the version. Nothing is
/// installed for the user: Download opens the DMG.
@MainActor
final class UpdateChecker: ObservableObject {
  static let shared = UpdateChecker()
  static let notifyKey = "updates.notify"
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

  @Published private(set) var state: State = .idle
  /// A newer release the user hasn't skipped; the menu bar menu offers it.
  @Published private(set) var pending: AppRelease?
  /// On unless the user turned update notices off.
  @Published private(set) var notify = UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true

  private var window: NSWindow?
  private var dailyTimer: Timer?
  /// A check found an update while the user was in another app.
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

  private init() {
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.alertWhenActive else { return }
        self.alertWhenActive = false
        self.showWindow(activate: false)
      }
    }
  }

  // MARK: schedule

  func appLaunched() {
    // 2.2.0 asked first; that answer and its launch count no longer apply.
    for key in ["updates.automaticChecks", "updates.launches"] { UserDefaults.standard.removeObject(forKey: key) }
    schedule()
  }

  /// From the update window's "don't tell me" box or Settings.
  func setNotify(_ on: Bool) {
    notify = on
    UserDefaults.standard.set(on, forKey: Self.notifyKey)
    log.notice("update notices \(on ? "on" : "off", privacy: .public)")
    schedule()
  }

  private func schedule() {
    dailyTimer?.invalidate()
    dailyTimer = nil
    guard notify else { return }
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
    guard notify else { return }
    let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    if let last, Date().timeIntervalSince(last) < Self.interval { return }
    await check()
    guard let pending else { return }
    log.notice("found \(pending.tag, privacy: .public)")
    // Never take focus from another app: wait until the user is in this one.
    if NSApp.isActive { showWindow(activate: false) } else { alertWhenActive = true }
  }

  // MARK: actions

  /// Check for Updates…: always checks, always answers.
  func checkNow() {
    state = .checking
    showWindow(activate: true)
    Task { await check(ignoringSkipped: true) }
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
    switch state {
    case .available(let releases):
      UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
      availableReleases = releases
      let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
      let newest = releases.first
      pending = ignoringSkipped || newest?.version?.description != skipped ? newest : nil
      log.notice("update available: \(newest?.tag ?? "", privacy: .public) (\(releases.count) newer than \(self.current.description, privacy: .public))")
    case .upToDate:
      UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
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

  /// `activate` only for what the user asked for; a scheduled notice appears
  /// without pulling the app in front.
  private func showWindow(activate: Bool) {
    if window == nil {
      log.notice("showing the Software Update window")
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
