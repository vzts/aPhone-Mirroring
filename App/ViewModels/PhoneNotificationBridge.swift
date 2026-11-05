import AppKit
import ADBKit
import ScrcpyClient
import SharedModels
import UserNotifications
import os

private let log = Logger(subsystem: "io.github.vzts.aphonemirroring", category: "notifications")

/// Shows a connected phone's notifications in the Mac's Notification Center
/// (Settings › General › Show phone notifications on this Mac).
///
/// Nothing is installed on the phone: adb's shell may list and read its
/// notifications (`PhoneNotificationWatcher`). New ones appear here, updates
/// replace them, and dismissing one on the phone removes it here too.
/// Clicking one opens the app on the phone and its mirror.
@MainActor
final class PhoneNotificationBridge: NSObject, UNUserNotificationCenterDelegate {
  static let shared = PhoneNotificationBridge()
  static let enabledKey = "notifications.forward"
  private static let labelsKey = "notifications.appLabels"

  private let adb = ADBClient()
  private var center: UNUserNotificationCenter { .current() }
  private var watchers: [String: Task<Void, Never>] = [:]
  private var devices: [Device] = []
  /// Package → the app's name on the phone, kept across launches.
  private var labels = UserDefaults.standard.dictionary(forKey: labelsKey) as? [String: String] ?? [:]
  /// One app-list read at a time per phone, and not again for a while.
  private var labelReads: [String: (task: Task<Void, Never>, at: Date)] = [:]

  var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

  /// Every device-list change lands here: one watcher per online phone while
  /// the setting is on.
  func sync(devices: [Device]) {
    self.devices = devices
    let wanted = isEnabled ? Set(devices.filter { $0.state == .online }.map(\.id)) : []
    for (serial, task) in watchers where !wanted.contains(serial) {
      task.cancel()
      watchers[serial] = nil
      labelReads[serial] = nil
    }
    for device in devices where wanted.contains(device.id) && watchers[device.id] == nil {
      let serial = device.id
      let watcher = PhoneNotificationWatcher(adb: adb, serial: serial) { [weak self] change in
        await self?.handle(change, serial: serial)
      }
      watchers[serial] = Task { await watcher.run() }
      log.notice("watching notifications on \(serial, privacy: .public)")
      // The first read of app names takes seconds; don't make the first
      // notification wait for it.
      if labels.isEmpty, labelReads[serial] == nil {
        labelReads[serial] = (Task { await self.readLabels(serial: serial) }, Date())
      }
    }
  }

  /// The setting was switched: start or stop watching.
  func settingChanged() {
    sync(devices: devices)
  }

  /// Asks macOS the first time (later calls just return the answer given).
  func askForPermission() async -> UNAuthorizationStatus {
    do {
      let granted = try await center.requestAuthorization(options: [.alert, .sound])
      log.notice("notification permission \(granted ? "granted" : "not granted", privacy: .public)")
    } catch {
      log.error("notification permission request failed: \(error.localizedDescription, privacy: .public)")
    }
    return await center.notificationSettings().authorizationStatus
  }

  // MARK: phone → Mac

  private func handle(_ change: PhoneNotificationWatcher.Change, serial: String) async {
    switch change {
    case .posted(let notification, let isUpdate):
      await post(notification, serial: serial, isUpdate: isUpdate)
    case .removed(let key):
      center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(serial, key)])
    }
  }

  private func post(_ notification: PhoneNotification, serial: String, isUpdate: Bool) async {
    let app = await label(for: notification.packageName, serial: serial)
    let content = UNMutableNotificationContent()
    if notification.title.isEmpty {
      content.title = app
    } else {
      content.title = notification.title
      content.subtitle = app
    }
    // With more than one phone connected, say which one.
    if watchers.count > 1, let phone = devices.first(where: { $0.id == serial }) {
      content.subtitle = [content.subtitle, phone.displayName].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    content.body = notification.text
    content.threadIdentifier = "\(serial)|\(notification.packageName)"
    content.userInfo = ["serial": serial, "package": notification.packageName]
    // An update the app asked not to alert again for replaces the old one quietly.
    if !(isUpdate && notification.flags.contains("ONLY_ALERT_ONCE")) { content.sound = .default }
    let request = UNNotificationRequest(identifier: Self.identifier(serial, notification.key), content: content, trigger: nil)
    do {
      try await center.add(request)
      log.info("showed a notification from \(notification.packageName, privacy: .public)")
    } catch {
      log.error("couldn't show a notification: \(error.localizedDescription, privacy: .public)")
    }
  }

  private static func identifier(_ serial: String, _ key: String) -> String { "\(serial)|\(key)" }

  // MARK: app names

  /// The app's name as the phone shows it. The phone only gives package
  /// names with notifications, so the names of its apps are read once (the
  /// bundled scrcpy server can list them) and kept; until then, or for an
  /// app that isn't listed, the package name stands in.
  private func label(for package: String, serial: String) async -> String {
    if let known = labels[package] { return known }
    if let read = labelReads[serial], Date().timeIntervalSince(read.at) < 600 {
      await read.task.value
    } else {
      let task = Task { await self.readLabels(serial: serial) }
      labelReads[serial] = (task, Date())
      await task.value
    }
    return labels[package] ?? package
  }

  private func readLabels(serial: String) async {
    guard let resources = try? ResourceLocator.scrcpyResources(), let adbBinary = resources.adbBinary else { return }
    let remote = "/data/local/tmp/scrcpy-server-applist.jar"
    let pushed = await Task.detached {
      let push = Process()
      push.executableURL = adbBinary
      push.arguments = ["-s", serial, "push", resources.serverJar.path, remote]
      push.standardOutput = FileHandle.nullDevice
      push.standardError = FileHandle.nullDevice
      guard (try? push.run()) != nil else { return false }
      push.waitUntilExit()
      return push.terminationStatus == 0
    }.value
    guard pushed else { return }
    let command = "CLASSPATH=\(remote) app_process / com.genymobile.scrcpy.Server "
      + "\(ScrcpyServerVersion.current) list_apps=true log_level=info; rm -f \(remote)"
    guard let output = try? await adb.shell(command, serial: serial) else { return }
    let found = PhoneNotificationParser.parseAppList(output)
    log.notice("read \(found.count) app names from \(serial, privacy: .public)")
    guard !found.isEmpty else { return }
    labels.merge(found) { _, new in new }
    UserDefaults.standard.set(labels, forKey: Self.labelsKey)
  }

  // MARK: Mac → phone

  /// Clicking a notification opens its app on the phone and the phone's mirror.
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let info = response.notification.request.content.userInfo
    guard let serial = info["serial"] as? String, let package = info["package"] as? String else { return }
    await open(package: package, serial: serial)
  }

  /// Show phone notifications even while this app is in front.
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  private func open(package: String, serial: String) async {
    guard let device = devices.first(where: { $0.id == serial && $0.state == .online }) else { return }
    // A package name is letters, digits, dots and underscores; anything else
    // stays out of the shell. (`monkey -p` started nothing on Android 16.)
    if package.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) {
      _ = try? await adb.shell(
        "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p \(package)", serial: serial)
    }
    NSApp.activate()
    await SessionCoordinator.shared.startMirror(for: device)
  }
}
