import Foundation

/// Follows one phone's notifications and reports what's new, updated or gone.
///
/// The phone logs every post, update and removal to its event log
/// (`notification_enqueue` / `notification_canceled`). A `logcat` stream of
/// those wakes the watcher, which compares update times and reads only what
/// changed; a slow check covers a stream that drops. What's already showing
/// when the watcher starts counts as seen, so connecting doesn't replay it.
///
/// A post is logged when it's enqueued and listed a few hundred ms later
/// (measured 200–500 ms on the Android 16 emulator), so an event schedules
/// reads shortly after it rather than at once.
public actor PhoneNotificationWatcher {
  public enum Change: Sendable {
    case posted(PhoneNotification, isUpdate: Bool)
    case removed(key: String)
  }

  /// System notifications (debugging connected, charging, …) are all ongoing
  /// anyway; skipping them saves a read each.
  static let ignoredPackages: Set<String> = ["android", "com.android.systemui"]
  static let eventsCommand = "logcat -b events -v raw -T 1 -s notification_enqueue notification_canceled"

  private let adb: ADBClient
  private let serial: String
  private let onChange: @Sendable (Change) async -> Void
  private var known: [String: String]?
  /// Reads events have asked for.
  private var due: [ContinuousClock.Instant] = []
  /// After an event: when the post has landed, and again for a slow phone.
  static let followUps: [Duration] = [.milliseconds(600), .seconds(2), .seconds(5)]

  public init(adb: ADBClient, serial: String, onChange: @escaping @Sendable (Change) async -> Void) {
    self.adb = adb
    self.serial = serial
    self.onChange = onChange
  }

  /// Runs until the task is cancelled.
  public func run(checkEvery interval: Duration = .seconds(20)) async {
    let listener = Task { await listen() }
    defer { listener.cancel() }
    let clock = ContinuousClock()
    var lastRead = clock.now - interval
    while !Task.isCancelled {
      let now = clock.now
      let asked = due.contains { $0 <= now }
      // At most one read a second, so a notification that updates constantly
      // (a download's progress) doesn't keep the phone busy.
      if (asked && now - lastRead >= .seconds(1)) || now - lastRead >= interval {
        due.removeAll { $0 <= now }
        lastRead = now
        await refresh()
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  /// Any line from the event log means something changed; `refresh` finds what.
  private func listen() async {
    while !Task.isCancelled {
      if let conn = try? await adb.openShell(Self.eventsCommand, serial: serial) {
        await withTaskCancellationHandler {
          while !Task.isCancelled {
            guard let chunk = try? await conn.readAvailable(maxLength: 4096), !chunk.isEmpty else { break }
            let now = ContinuousClock.now
            due += Self.followUps.map { now + $0 }
          }
        } onCancel: {
          Task { await conn.close() }
        }
        await conn.close()
      }
      try? await Task.sleep(for: .seconds(5))
    }
  }

  private func refresh() async {
    guard let raw = try? await adb.shell(PhoneNotificationParser.signatureCommand, serial: serial),
          let current = PhoneNotificationParser.parseSignatures(raw)
    else { return }
    guard let previous = known else {
      known = current
      return
    }
    for key in previous.keys where current[key] == nil {
      await onChange(.removed(key: key))
    }
    let changed = current.keys.filter {
      previous[$0] != current[$0]
        && !Self.ignoredPackages.contains(PhoneNotificationParser.packageName(ofKey: $0))
    }
    if !changed.isEmpty {
      guard let dump = try? await adb.shell(PhoneNotificationParser.recordsCommand(keys: changed), serial: serial),
            let records = PhoneNotificationParser.parseRecords(dump)
      else {
        // Keep the old times for what changed, so the next check tries again.
        known = previous.filter { current[$0.key] != nil }
        return
      }
      for notification in records where notification.isAlerting {
        await onChange(.posted(notification, isUpdate: previous[notification.key] != nil))
      }
    }
    known = current
  }
}
