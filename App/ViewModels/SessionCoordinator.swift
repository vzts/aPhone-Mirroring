import Foundation
import AppKit
import ADBKit
import DeviceDiscovery
import ScrcpyClient
import MirrorEngine
import FusionEngine
import SharedModels
import os

private let log = Logger(subsystem: "com.droidmirroring.app", category: "coordinator")

/// Top-level glue between UI and engines. Owned by `DroidMirroringApp`.
///
/// Per-device state machine:
///   1. User picks a device → `startMirror`
///   2. We pick the largest active physical display (folded outer / unfolded inner)
///      and launch a scrcpy session pinned to its display_id
///   3. A 1.5s poll watches for fold/unfold; on change we tear the session down and
///      relaunch on the new display_id. The mirror window stays open and just
///      re-receives the new size via `onDimensionsChanged` → auto-resize.
@MainActor
final class SessionCoordinator: ObservableObject {
  static let shared = SessionCoordinator()

  /// Best-effort synchronous cleanup invoked from the AppDelegate's
  /// `applicationShouldTerminate`. Stops every live mirror / fusion / files
  /// window in parallel so scrcpy-server's `cleanup=true` hook fires before we
  /// die, releasing any virtual displays on the device.
  func shutdownEverything() async {
    await withTaskGroup(of: Void.self) { group in
      for (_, controller) in mirrorWindows {
        group.addTask { await controller.session.stop() }
      }
      for (_, controller) in fusionWindows {
        group.addTask {
          if let f = await controller.fusion { await f.mirrorSession.stop() }
        }
      }
      for (serial, token) in freeformTokens {
        if let activator = freeformActivators[serial] {
          group.addTask { await activator.deactivate(token) }
        }
      }
    }
    mirrorWindows.removeAll()
    fusionWindows.removeAll()
    freeformTokens.removeAll()
    freeformActivators.removeAll()
  }

  private let adb = ADBClient()
  private var mirrorWindows: [String: MirrorWindowController] = [:]
  private var filesWindows: [String: FilesWindowController] = [:]
  private var fusionWindows: [String: FusionAppWindowController] = [:]
  private var freeformActivators: [String: FreeformActivator] = [:]
  private var freeformTokens: [String: ActivationToken] = [:]
  private var activePanel: [String: (id: Int, width: Int, height: Int, rotation: Int)] = [:]
  private var pollTasks: [String: Task<Void, Never>] = [:]
  private var autoMirroredSerials: Set<String> = []
  private var connectController: ConnectWindowController?
  /// Online serials at the moment the user asked for the Connect window while
  /// already mirroring; it stays up until a phone outside this set appears.
  private var connectBaseline: Set<String>?
  /// The user closed the idle Connect window; don't push it back until the
  /// next mirror session ends or they ask for it.
  private var connectDismissed = false
  private var lastOnlineSerials: Set<String> = []
  /// Set by the app delegate; the Connect window lists its online devices.
  weak var monitor: DeviceMonitor?

  private var trustedKey = "mirror.trustedDeviceSerials"
  private var trusted: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: trustedKey) ?? []) }
    set { UserDefaults.standard.set(Array(newValue), forKey: trustedKey) }
  }
  func trustDevice(_ s: String) { var x = trusted; x.insert(s); trusted = x }
  var hasActiveSession: Bool { !mirrorWindows.isEmpty || !fusionWindows.isEmpty }

  /// Called from the App on every DeviceMonitor publish. Opens Mirror for the
  /// first online device we haven't already auto-mirrored this session,
  /// provided the user hasn't disabled the auto-mirror preference.
  /// Also tears down Mirror/Files for devices that just disappeared, and
  /// toggles the "no device connected" placeholder window.
  func autoMirrorIfNeeded(devices: [Device]) {
    let online = devices.filter { $0.state == .online }
    let onlineSerials = Set(online.map(\.id))
    lastOnlineSerials = onlineSerials

    // Reap zombies — when USB is unplugged the device drops out of the publish
    // list, but our Mirror controller still holds a frozen frame. Close it so
    // the Waiting placeholder can take over.
    for serial in Array(mirrorWindows.keys) where !onlineSerials.contains(serial) {
      log.notice("device \(serial) gone — closing Mirror")
      mirrorWindows.removeValue(forKey: serial)?.close()
      pollTasks[serial]?.cancel()
      pollTasks.removeValue(forKey: serial)
      activePanel.removeValue(forKey: serial)
      autoMirroredSerials.remove(serial)
    }
    for serial in Array(filesWindows.keys) where !onlineSerials.contains(serial) {
      filesWindows[serial]?.close()
      filesWindows.removeValue(forKey: serial)
    }

    let autoEnabled = UserDefaults.standard.object(forKey: "mirror.autoOnConnect") as? Bool ?? true
    let known = trusted
    let willAutoMirror = autoEnabled && online.contains {
      known.contains($0.id) && mirrorWindows[$0.id] == nil && !autoMirroredSerials.contains($0.id)
    }
    syncConnectWindow(willMirror: willAutoMirror)

    guard autoEnabled else { return }
    for device in online {
      if mirrorWindows[device.id] != nil { continue }
      if autoMirroredSerials.contains(device.id) { continue }
      if !known.contains(device.id) { continue }
      autoMirroredSerials.insert(device.id)
      Task { await startMirror(for: device) }
      break
    }
  }

  // MARK: Live settings

  private var settingsRestart: Task<Void, Never>?

  /// Quality, sound, and keep-awake are scrcpy-server launch options, so open
  /// mirrors restart to pick them up. Debounced so dragging the bitrate slider
  /// restarts once, after it settles.
  func mirrorLaunchSettingsChanged(refreshAudio: Bool = false) {
    settingsRestart?.cancel()
    settingsRestart = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 700_000_000)
      guard !Task.isCancelled, let self else { return }
      for (serial, controller) in Array(self.mirrorWindows) {
        controller.isRestarting = true
        await self.restartMirror(for: serial)
        if refreshAudio { self.mirrorWindows[serial]?.refreshAudioOutput() }
      }
    }
  }

  /// Title-bar button and Device menu: flip the setting itself, then apply.
  func setPhoneScreenOff(_ on: Bool) {
    UserDefaults.standard.set(on, forKey: "mirror.autoScreenOff")
    phoneScreenOffChanged(on)
  }

  func phoneScreenOffChanged(_ on: Bool) {
    mirrorWindows.values.forEach { $0.applyPhoneScreenOff(on) }
  }

  func clipboardSyncChanged(_ on: Bool) {
    mirrorWindows.values.forEach { $0.applyClipboardSync(on) }
  }

  // MARK: Connect window

  /// Show the Connect window whenever nothing is mirroring and no trusted
  /// phone is about to be; hide it as soon as a Mirror takes over.
  func syncConnectWindow(willMirror: Bool = false) {
    if let baseline = connectBaseline {
      let newPhone = !lastOnlineSerials.subtracting(baseline).isEmpty
      if newPhone && (willMirror || !mirrorWindows.isEmpty) { closeConnectWindow() }
      return
    }
    if willMirror || !mirrorWindows.isEmpty {
      closeConnectWindow()
    } else if !connectDismissed {
      presentConnectWindow(userInitiated: false)
    }
  }

  /// User-initiated: menu bar "Connect a Phone…", Dock click with nothing open.
  func showConnectWindow() {
    connectDismissed = false
    connectBaseline = mirrorWindows.isEmpty ? nil : lastOnlineSerials
    presentConnectWindow(userInitiated: true)
  }

  /// Device-list updates arrive constantly; only a new window or an explicit
  /// request may come forward, or the app would keep stealing focus.
  private func presentConnectWindow(userInitiated: Bool) {
    let isNew = connectController == nil
    if isNew {
      let wc = ConnectWindowController(monitor: monitor)
      connectController = wc
      NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: wc.window, queue: .main) { [weak self, weak wc] _ in
        MainActor.assumeIsolated {
          // Still registered means the user closed it (we unregister before closing).
          guard let self, let wc, self.connectController === wc else { return }
          wc.pairing.stop()
          self.connectController = nil
          self.connectBaseline = nil
          self.connectDismissed = true
        }
      }
    }
    guard isNew || userInitiated else { return }
    if userInitiated { NSApp.activate(ignoringOtherApps: true) }
    connectController?.showWindow(nil)
    connectController?.window?.makeKeyAndOrderFront(nil)
  }

  private func closeConnectWindow() {
    guard let wc = connectController else { return }
    connectController = nil
    connectBaseline = nil
    wc.close()
  }

  func startMirror(for device: Device) async {
    trustDevice(device.id)
    if let existing = mirrorWindows[device.id] {
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    let pick = try? await adb.pickActiveDisplay(serial: device.id)
    let displayId = pick?.id ?? 0
    activePanel[device.id] = (
      id: displayId,
      width: pick?.width ?? 0,
      height: pick?.height ?? 0,
      rotation: pick?.rotation ?? 0
    )
    var controller: MirrorWindowController?
    do {
      let c = try makeMirrorWindow(for: device)
      controller = c
      try await launchSession(for: device, displayId: displayId, into: c)
      startActiveDisplayPolling(for: device)
    } catch {
      // ── Audio fallback ──────────────────────────────────────────────
      // If the device has no audio HAL (e.g. ZTE F50), scrcpy-server may
      // either (a) time out on the audio socket → audioUnavailable, or
      // (b) crash entirely → scrcpyProtocol / short read.  In both cases
      // retry with audio disabled so the user at least gets video.
      let isAudioError: Bool = {
        if case DroidMirroringError.audioUnavailable = error { return true }
        return false
      }()
      let isScrcpyError: Bool = {
        if case DroidMirroringError.scrcpyProtocol = error { return true }
        return false
      }()
      if (isAudioError || isScrcpyError), let c = controller {
        let reason = isAudioError ? "audio unavailable" : "scrcpy protocol error"
        log.warning("\(reason) for \(device.id) — retrying without audio")
        // Clean up the failed server process + reverse forward before retrying.
        await c.session.stop()
        do {
          try await launchSession(for: device, displayId: displayId, into: c, audioEnabled: false)
          startActiveDisplayPolling(for: device)
          log.notice("mirror started without audio for \(device.id)")
          return
        } catch {
          log.error("audio-disabled retry also failed for \(device.id): \(error)")
        }
        // Some phones' HEVC / AV1 encoders don't start at all; H.264 works on
        // every Android device, so give it one last try before giving up.
        if (UserDefaults.standard.string(forKey: "mirror.codec") ?? "h265") != "h264" {
          await c.session.stop()
          do {
            try await launchSession(for: device, displayId: displayId, into: c, audioEnabled: false, codecOverride: "h264")
            startActiveDisplayPolling(for: device)
            log.notice("mirror started with H.264 fallback for \(device.id)")
            return
          } catch {
            log.error("H.264 fallback also failed for \(device.id): \(error)")
          }
        }
      }

      // If launch failed due to a bad display_id, clear the cache and retry with display 0.
      // Skip this if we already retried above (audio / scrcpy error).
      if !isAudioError && !isScrcpyError {
        let errDesc = error.localizedDescription
        if errDesc.contains("display") || errDesc.contains("short read") || errDesc.contains("scrcpy") {
          log.error("launch failed for \(device.id): \(error). Retrying with displayId=0...")
          activePanel.removeValue(forKey: device.id)
          mirrorWindows.removeValue(forKey: device.id)?.close()
          // Retry
          do {
            let controller = try makeMirrorWindow(for: device)
            try await launchSession(for: device, displayId: 0, into: controller)
            startActiveDisplayPolling(for: device)
            return
          } catch {
            // Second failure — show detailed alert
          }
        }
      }

      let name = device.displayName
      let detailMsg = String(localized: "If this keeps happening, open Settings › Advanced, choose Remove Leftover Mirroring Files, then reconnect the phone.")
        + "\n\n\(name) · \(androidVersionName(sdk: device.androidSDK)) · \(device.transport.rawValue)\n\(error.localizedDescription)"
      mirrorWindows.removeValue(forKey: device.id)?.close()
      let alert = NSAlert()
      alert.messageText = String(localized: "Couldn't start mirroring")
      alert.informativeText = detailMsg
      alert.addButton(withTitle: String(localized: "OK"))
      alert.runModal()
      syncConnectWindow()
    }
  }

  /// One place that creates, registers, and shows a Mirror window, so every
  /// path gets the same close handling and hands off from the Connect window.
  private func makeMirrorWindow(for device: Device) throws -> MirrorWindowController {
    let c = try MirrorWindowController(deviceName: device.displayName)
    c.deviceSerial = device.id
    mirrorWindows[device.id] = c
    let serial = device.id
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: c.window, queue: .main) { [weak self, weak c] _ in
      MainActor.assumeIsolated {
        // Programmatic closes unregister first, so a hit here is the user's red button.
        guard let self, let c, self.mirrorWindows[serial] === c else { return }
        self.mirrorWindows.removeValue(forKey: serial)
        self.pollTasks.removeValue(forKey: serial)?.cancel()
        self.activePanel.removeValue(forKey: serial)
        self.connectDismissed = true
      }
    }
    connectDismissed = false
    c.showWindow(nil)
    closeConnectWindow()
    return c
  }

  func openFiles(for device: Device) {
    trustDevice(device.id)
    if let existing = filesWindows[device.id] {
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = FilesWindowController(device: device)
    filesWindows[device.id] = controller
    controller.showWindow(nil)
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: controller.window,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.filesWindows.removeValue(forKey: device.id)
      }
    }
  }

  // MARK: fusion mode

  func appCatalog() -> AppCatalog {
    AppCatalog(adb: adb)
  }

  /// Open a single Android desktop on a virtual display, no specific app forced.
  /// Used by the "Desktop Mode" button — the device shows whatever its launcher
  /// (Samsung DeX / Pixel / AOSP) puts on a secondary display.
  func openDesktop(for device: Device, size: CGSize = CGSize(width: 2560, height: 1440), dpi: Int = 160) async {
    trustDevice(device.id)
    let pseudoApp = InstalledApp(packageName: "desktop", label: "Desktop", iconPNG: nil)
    let key = fusionKey(serial: device.id, packageName: pseudoApp.packageName)
    if let existing = fusionWindows[key] {
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    do {
      let activator = freeformActivators[device.id] ?? FreeformActivator(adb: adb)
      freeformActivators[device.id] = activator
      if freeformTokens[device.id] == nil {
        freeformTokens[device.id] = try await activator.activate(serial: device.id)
      }

      let controller = try FusionAppWindowController(appLabel: String(localized: "Desktop — \(device.displayName)"))
      fusionWindows[key] = controller
      controller.showWindow(nil)

      let renderer = controller.renderer
      let resources = try ResourceLocator.scrcpyResources()
      let launcher = FusionLauncher(adb: adb, scrcpyResources: resources)
      let session = try await launcher.openDesktop(
        serial: device.id,
        size: size,
        dpi: dpi,
        frameSink: { pixelBuffer, _ in
          renderer.render(pixelBuffer: pixelBuffer)
        }
      )
      await controller.attach(session)

      NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: controller.window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          await self?.fusionWindowDidClose(deviceSerial: device.id, packageName: pseudoApp.packageName)
        }
      }
    } catch {
      NSAlert(error: error).runModal()
      fusionWindows[key]?.close()
      fusionWindows[key] = nil
    }
  }

  /// Launch one Android app into its own borderless window. Activates the
  /// device-wide freeform settings on first launch per-session; the snapshot
  /// is restored when the last Fusion window for that device closes.
  func launchFusionApp(for device: Device, app: InstalledApp, size: CGSize = CGSize(width: 2560, height: 1440), dpi: Int = 160) async {
    trustDevice(device.id)
    let key = fusionKey(serial: device.id, packageName: app.packageName)
    if let existing = fusionWindows[key] {
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    do {
      let activator = freeformActivators[device.id] ?? FreeformActivator(adb: adb)
      freeformActivators[device.id] = activator
      if freeformTokens[device.id] == nil {
        freeformTokens[device.id] = try await activator.activate(serial: device.id)
      }

      let controller = try FusionAppWindowController(appLabel: app.label)
      fusionWindows[key] = controller
      controller.showWindow(nil)

      let renderer = controller.renderer
      let resources = try ResourceLocator.scrcpyResources()
      let launcher = FusionLauncher(adb: adb, scrcpyResources: resources)
      let session = try await launcher.launch(
        packageName: app.packageName,
        serial: device.id,
        size: size,
        dpi: dpi,
        frameSink: { pixelBuffer, _ in
          renderer.render(pixelBuffer: pixelBuffer)
        }
      )
      await controller.attach(session)

      NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: controller.window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          await self?.fusionWindowDidClose(deviceSerial: device.id, packageName: app.packageName)
        }
      }
    } catch {
      NSAlert(error: error).runModal()
      fusionWindows[key]?.close()
      fusionWindows[key] = nil
    }
  }

  private func fusionWindowDidClose(deviceSerial: String, packageName: String) async {
    let key = fusionKey(serial: deviceSerial, packageName: packageName)
    fusionWindows.removeValue(forKey: key)
    // When the last Fusion window for this device closes, restore the global settings.
    let stillOpen = fusionWindows.keys.contains { $0.hasPrefix(deviceSerial + "|") }
    if !stillOpen,
       let token = freeformTokens.removeValue(forKey: deviceSerial),
       let activator = freeformActivators[deviceSerial] {
      await activator.deactivate(token)
    }
  }

  private func fusionKey(serial: String, packageName: String) -> String {
    "\(serial)|\(packageName)"
  }

  func stopMirror(for device: Device) async {
    pollTasks[device.id]?.cancel(); pollTasks.removeValue(forKey: device.id); activePanel.removeValue(forKey: device.id)
    for key in fusionWindows.keys.filter({ $0.hasPrefix(device.id + "|") }) { fusionWindows[key]?.close(); fusionWindows[key] = nil }
    if let t = freeformTokens.removeValue(forKey: device.id), let a = freeformActivators[device.id] { await a.deactivate(t) }
    guard let controller = mirrorWindows.removeValue(forKey: device.id) else { return }
    await controller.session.stop(); controller.close()
  }

  func disconnectWirelessDevice(for device: Device) async {
    guard device.transport == .wifi else { return }
    if let mc = mirrorWindows[device.id] {
      pollTasks[device.id]?.cancel(); pollTasks.removeValue(forKey: device.id); activePanel.removeValue(forKey: device.id)
      autoMirroredSerials.remove(device.id)
      mirrorWindows.removeValue(forKey: device.id)
      await mc.session.stop(); mc.close()
    }
    for key in fusionWindows.keys.filter({ $0.hasPrefix(device.id + "|") }) { fusionWindows[key]?.close(); fusionWindows[key] = nil }
    if let t = freeformTokens.removeValue(forKey: device.id), let a = freeformActivators[device.id] { await a.deactivate(t) }
    filesWindows[device.id]?.close(); filesWindows.removeValue(forKey: device.id); autoMirroredSerials.remove(device.id)
    let parts = device.id.split(separator: ":").map(String.init)
    if parts.count == 2, let p = Int(parts[1]) {
      do { try await ResourceLocator.wirelessClient().disconnect(host: parts[0], port: p); log.notice("disconnected \(device.id)") }
      catch { log.error("disconnect error: \(error)") }
    } else {
      let b = Bundle.main.url(forResource: "adb", withExtension: nil) ?? URL(fileURLWithPath: "/usr/local/bin/adb")
      let pr = Process(); pr.executableURL = b; pr.arguments = ["disconnect", device.id]
      let pp = Pipe(); pr.standardOutput = pp; pr.standardError = pp
      do { try pr.run(); pr.waitUntilExit(); log.notice("disconnected \(device.id)") }
      catch { log.error("disconnect error: \(error)") }
    }
  }

  // MARK: launch / relaunch

  private func launchSession(
    for device: Device,
    displayId: Int,
    into controller: MirrorWindowController,
    audioEnabled: Bool = true,
    codecOverride: String? = nil
  ) async throws {
    let resources = try ResourceLocator.scrcpyResources()
    let launcher = ScrcpyServerLauncher(adb: adb, serial: device.id, resources: resources)

    // Video knobs from Settings. Defaults: H.265 at 60 fps and 8 Mbps — the
    // phone's native resolution stays sharp in motion at that rate, and heat
    // depends far more on frame rate than on bitrate.
    let defaults = UserDefaults.standard
    let codec = codecOverride ?? defaults.string(forKey: "mirror.codec") ?? "h265"
    let bitrateMbps = (defaults.object(forKey: "mirror.bitrate") as? Int) ?? 8
    let maxFps = (defaults.object(forKey: "mirror.maxFps") as? Int) ?? 60
    let audioOutput = defaults.string(forKey: "mirror.audioOutput") ?? "mac"
    // A sleeping phone drops its wireless-debugging link, which tears the
    // mirror down, so it's held awake (screen timeout 30 min) while mirroring.
    // Not a setting: turning it off would only ever break the mirror.
    await prepareScreenOffTimeout(serial: device.id)

    let options = ScrcpyOptions(
      videoBitRate: bitrateMbps * 1_000_000,
      maxFps: maxFps,
      videoCodec: codec,
      audioCodec: "opus",
      audioEnabled: audioEnabled && audioOutput == "mac",
      controlEnabled: true,
      displayId: displayId,
      screenOffTimeoutMs: Self.keepAwakeScreenOffTimeoutMs
    )
    try await controller.session.start(launcher: launcher, options: options)
    await controller.bindControl()
  }

  private static let keepAwakeScreenOffTimeoutMs = 30 * 60 * 1000

  /// scrcpy-server records the current `screen_off_timeout` and its CleanUp
  /// process restores it when the server dies. On a relaunch the previous
  /// server's value can still be in place (its CleanUp hasn't run yet, or was
  /// lost to a reboot), so the new server would record our own value and never
  /// restore. Remember the phone's real value and put it back before launching.
  private func prepareScreenOffTimeout(serial: String) async {
    let key = "mirror.originalScreenOffTimeout.\(serial)"
    let raw = try? await adb.shell("settings get system screen_off_timeout", serial: serial)
    guard let current = raw.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return }
    if current != Self.keepAwakeScreenOffTimeoutMs {
      UserDefaults.standard.set(current, forKey: key)
      return
    }
    guard let original = UserDefaults.standard.object(forKey: key) as? Int else { return }
    log.notice("restoring leftover screen_off_timeout to \(original) before launch")
    _ = try? await adb.shell("settings put system screen_off_timeout \(original)", serial: serial)
  }

  /// Tear down and re-launch the scrcpy session for `serial` without closing
  /// the mirror window.  Used when a runtime setting (audio output mode)
  /// changes and requires a new server-side configuration.  The controller's
  /// `isRestarting` flag is set by the caller so `bindControl()` can skip
  /// one-shot initialisation (auto-screen-off, audio mute, clipboard reset).
  func restartMirror(for serial: String) async {
    guard let controller = mirrorWindows[serial] else { return }
    pollTasks[serial]?.cancel()
    pollTasks[serial] = nil
    let displayId = activePanel[serial]?.id ?? 0

    let device = Device(
      id: serial,
      model: await controller.session.deviceName,
      state: .online
    )

    await controller.session.stop()

    do {
      try await launchSession(for: device, displayId: displayId, into: controller)
      startActiveDisplayPolling(for: device)
      log.notice("session restarted for \(serial)")
    } catch {
      log.error("restart failed for \(serial): \(error)")
      controller.isRestarting = false
      mirrorWindows.removeValue(forKey: serial)
      activePanel.removeValue(forKey: serial)
      controller.close()
    }
  }

  // MARK: fold/unfold polling

  private func startActiveDisplayPolling(for device: Device) {
    pollTasks[device.id]?.cancel()
    log.notice("starting display poll for \(device.id)")
    pollTasks[device.id] = Task { [weak self] in
      guard let self else { return }
      var tick = 0
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else { return }
        tick += 1
        await self.checkActiveDisplay(for: device, tick: tick)
      }
      log.notice("poll task ended for \(device.id)")
    }
  }

  /// Manually trigger a re-pick — wired to Cmd+R from the mirror window. Also
  /// useful as a fallback if our poller fails to catch a fold/rotation event.
  func refreshActiveDisplay(for device: Device) async {
    log.notice("manual refresh for \(device.id)")
    await checkActiveDisplay(for: device, tick: -1, force: true)
  }

  private func checkActiveDisplay(for device: Device, tick: Int, force: Bool = false) async {
    guard let controller = mirrorWindows[device.id] else {
      log.notice("tick \(tick): no controller — stopping poll")
      return
    }
    let displays: [DisplayInfo]
    do {
      displays = try await adb.physicalDisplays(serial: device.id)
    } catch {
      log.error("tick \(tick): physicalDisplays error: \(error)")
      return
    }
    let ranked = displays.sorted { a, b in
      if a.state.rank != b.state.rank { return a.state.rank > b.state.rank }
      return a.area > b.area
    }
    let current = activePanel[device.id]
    guard let pick = ranked.first else { return }

    // Trigger a relaunch when ANY of (id, width, height, rotation) changes:
    // - id/dims: fold/unfold on foldables, external display attach
    // - rotation: portrait↔landscape within the same physical panel
    let changed = force
      || current == nil
      || current?.id != pick.id
      || current?.width != pick.width
      || current?.height != pick.height
      || current?.rotation != pick.rotation
    guard changed else { return }
    log.notice("PANEL CHANGED -> id=\(pick.id) \(pick.width)x\(pick.height) rot=\(pick.rotation)")
    activePanel[device.id] = (id: pick.id, width: pick.width, height: pick.height, rotation: pick.rotation)
    await controller.session.stop()
    do {
      try await launchSession(for: device, displayId: pick.id, into: controller)
      log.notice("relaunch OK id=\(pick.id) \(pick.width)x\(pick.height)")
    } catch {
      log.error("relaunch failed: \(error)")
    }
  }

  // MARK: troubleshooting

  /// Force-remove leftover scrcpy-server jars from all connected devices.
  func cleanupScrcpyServers() async throws {
    let devices = try await adb.listDevices()
    let online = devices.filter { $0.state == .online }
    guard !online.isEmpty else {
      throw DroidMirroringError.deviceNotFound("No online devices found")
    }
    for device in online {
      try await adb.shell("rm -f /data/local/tmp/scrcpy-server*.jar", serial: device.id)
      log.notice("cleaned scrcpy-server on \(device.id)")
    }
  }
}

enum ResourceLocator {
  static func scrcpyResources() throws -> ScrcpyServerLauncher.Resources {
    let bundle = Bundle.main
    guard let jar = bundle.url(forResource: "scrcpy-server", withExtension: "jar")
            ?? bundle.url(forResource: "scrcpy-server-v\(ScrcpyServerVersion.current)", withExtension: "jar")
    else {
      throw DroidMirroringError.scrcpyProtocol("scrcpy-server.jar not bundled — run scripts/fetch-scrcpy-server.sh")
    }
    let adb = bundle.url(forResource: "adb", withExtension: nil) ?? URL(fileURLWithPath: "/usr/local/bin/adb")
    return .init(serverJar: jar, adbBinary: adb)
  }

  static func wirelessClient() -> ADBWirelessClient {
    let adb = Bundle.main.url(forResource: "adb", withExtension: nil) ?? URL(fileURLWithPath: "/usr/local/bin/adb")
    return ADBWirelessClient(adbBinary: adb)
  }
}
