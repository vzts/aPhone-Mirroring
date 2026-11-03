import AppKit
import ADBKit
import CoreVideo
import CoreMedia
import MirrorEngine
import ScrcpyClient
import SharedModels
import SwiftUI

/// Free-standing mirror window. One per device.
@MainActor
final class MirrorWindowController: NSWindowController {
  let renderer: MetalFrameRenderer
  let session: MirrorSession
  let eventView: MirrorEventView
  let recorder = ScreenRecorder()
  private var titlebarControls: MirrorTitlebarControls?
  /// The rounded phone screen (mirror view's container), for the shutter flash.
  private weak var screenView: NSView?

  private var currentDeviceSize: CGSize = .zero
  private var hasSetInitialFrame = false
  private var isPinned = false
  private var isRecording = false
  private var isScreenOff = false
  /// "mac" | "phone" | "none" — persisted in UserDefaults
  private var audioOutput: String {
    UserDefaults.standard.string(forKey: "mirror.audioOutput") ?? "mac"
  }
  private var clipboardBridge: ClipboardBridge?
  private let deviceDisplayName: String

  // Screen-state poller — keeps `isScreenOff` in sync with the phone's real
  // display state so the UI doesn't drift after the user manually unlocks.
  private let adb = ADBClient()
  private var screenStatePoller: Timer?
  /// Settings › Mirroring › Turn off phone screen while mirroring, applied live.
  private var autoScreenOffEnabled = false
  /// Device media volume saved before we muted it — restored when switching
  /// back to "phone" mode so we don't leave the phone permanently silent.
  private var savedDeviceVolume: Int?

  // iPhone-Mirroring-style chrome auto-hide.
  // Starts true so the initial setChrome(revealed: false) actually hides it.
  private var chromeRevealed = true
  private var chromeHideTimer: Timer?
  private var mouseMonitor: Any?
  private var uhidKeyboard: UHIDKeyboardManager?
  private static let bezelInset: CGFloat = 8
  private static let bezelCornerRadius: CGFloat = 34
  private static let innerCornerRadius: CGFloat = 26
  /// Empty strip above the phone bezel — gives traffic lights and the overlay
  /// HUD their own real estate so they don't crowd the Android status bar.
  private static let chromeStrip: CGFloat = 32

  /// Set by SessionCoordinator after the controller is created.
  var deviceSerial: String?
  /// True while the session is being torn down and relaunched (audio mode
  /// change). Prevents `bindControl()` from re-applying audio / auto-screen-off
  /// on the fresh session so the window keeps its current state.
  var isRestarting = false

  init(deviceName: String) throws {
    let renderer = try MetalFrameRenderer()
    self.renderer = renderer
    self.eventView = MirrorEventView(layer: renderer.layer)
    self.session = MirrorSession { pixelBuffer, pts in
      renderer.render(pixelBuffer: pixelBuffer)
    }
    self.deviceDisplayName = deviceName.isEmpty ? "Mirror" : deviceName

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    // iPhone-Mirroring look: clear background, transparent titlebar with no
    // title text, soft drop shadow follows the rounded phone-bezel content.
    window.title = ""
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.isMovableByWindowBackground = true
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = true
    window.toolbarStyle = .unified
    window.contentAspectRatio = NSSize(
      width: ConnectWindowController.defaultDevice.width + 2 * Self.bezelInset,
      height: ConnectWindowController.defaultDevice.height + Self.chromeStrip + 2 * Self.bezelInset
    )

    // Wrap the Metal eventView in a rounded black phone-shell view.
    // Putting the inner-rounded mask on a *parent* NSView (instead of the
    // Metal layer itself) gives a clean clip — CAMetalLayer's own
    // cornerRadius/masksToBounds is flaky during resize animations.
    let screenClip = NSView()
    screenClip.wantsLayer = true
    screenClip.layer?.cornerRadius = Self.innerCornerRadius
    screenClip.layer?.cornerCurve = .continuous
    screenClip.layer?.masksToBounds = true
    screenClip.layer?.backgroundColor = NSColor.black.cgColor
    screenClip.addSubview(eventView)
    eventView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      eventView.leadingAnchor.constraint(equalTo: screenClip.leadingAnchor),
      eventView.trailingAnchor.constraint(equalTo: screenClip.trailingAnchor),
      eventView.topAnchor.constraint(equalTo: screenClip.topAnchor),
      eventView.bottomAnchor.constraint(equalTo: screenClip.bottomAnchor),
    ])
    self.screenView = screenClip
    let bezel = PhoneBezelView(
      content: screenClip,
      inset: Self.bezelInset,
      cornerRadius: Self.bezelCornerRadius
    )

    // Container that hosts both the phone bezel and the chrome strip above it.
    // Window background stays clear, so only the bezel (and overlay) cast a
    // shadow — the chrome strip is invisible until the HUD bar fades in.
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.clear.cgColor
    container.addSubview(bezel)
    bezel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      bezel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      bezel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      bezel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      bezel.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.chromeStrip),
    ])

    window.contentView = container
    window.isReleasedWhenClosed = false
    if let last = MirrorFramePersistence.lastFrame(),
       NSScreen.screens.contains(where: { $0.visibleFrame.intersects(last) }) {
      // Open where the phone was; the real aspect is applied on the first frame.
      window.setFrame(MirrorFramePersistence.fit(last, aspect: window.contentAspectRatio, in: window), display: false)
    } else {
      window.setFrame(PhoneWindowSizing.defaultFrame(aspect: window.contentAspectRatio, in: window, screen: NSScreen.main), display: false)
    }
    super.init(window: window)

    // Save the frame whenever it settles, not just on close — a crash or a
    // dropped connection shouldn't cost the user their window placement.
    for name in [NSWindow.willCloseNotification, NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
      NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.saveWindowFrame() }
      }
    }
    // The red button closes the NSWindow without calling this controller's
    // close(), so the session has to be torn down from the notification.
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.tearDown() }
    }

    // iPhone-Mirroring-style title bar: traffic lights on the left, Android
    // navigation on the right, both revealed when the pointer nears the top.
    let controls = MirrorTitlebarControls(
      onBack: { [weak self] in self?.sendBack() },
      onHome: { [weak self] in self?.sendHome() },
      onRecents: { [weak self] in self?.sendRecents() },
      onScreenshot: { [weak self] in self?.takeScreenshot() },
      onRecord: { [weak self] in self?.toggleRecord() },
      onRotate: { [weak self] in self?.rotateDevice() },
      onTogglePhoneScreen: { [weak self] in
        // Same single setting as Settings › Mirroring, so both always agree.
        guard let self else { return }
        SessionCoordinator.shared.setPhoneScreenOff(!self.autoScreenOffEnabled)
      },
      onMore: { [weak self] anchor in self?.showMoreMenu(anchor: anchor) }
    )
    self.titlebarControls = controls
    controls.setNavigationVisible(Self.showsNavigationButtons)
    container.addSubview(controls)
    controls.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      controls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
      controls.centerYAnchor.constraint(equalTo: container.topAnchor, constant: Self.chromeStrip / 2),
    ])

    renderer.onDimensionsChanged = { [weak self] size in
      Task { @MainActor in self?.applyDimensions(size) }
    }
    renderer.onFrame = { [weak self] buffer, pts in
      // Off the main thread — append synchronously into the recorder.
      self?.recorder.append(pixelBuffer: buffer, pts: pts)
    }

    // Hide all chrome by default; cursor near the top edge fades it back in.
    DispatchQueue.main.async { [weak self] in
      self?.setChrome(revealed: false, animated: false)
      window.invalidateShadow()
    }
    let mask: NSEvent.EventTypeMask = [
      .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
      .leftMouseDragged, .scrollWheel, .keyDown,
    ]
    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      if let self, event.window === self.window {
        // ⌘. — toggle the More panel (keyboard shortcut).
        if event.type == .keyDown,
           event.keyCode == 47,   // "." key
           event.modifierFlags.contains(.command) {
          Task { @MainActor in
            if let moreBtn = self.titlebarControls?.moreButton {
              self.showMoreMenu(anchor: moreBtn)
            }
          }
          return nil  // consume the event
        }
        Task { @MainActor in self.handleMouseMoved(event) }
      }
      return event
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func close() {
    tearDown()
    super.close()
  }

  private var didTearDown = false

  /// Stops the session and restores the phone. Runs once, however the window
  /// closes: programmatically through close() or with the red button.
  private func tearDown() {
    guard !didTearDown else { return }
    didTearDown = true
    uhidKeyboard?.destroy(); uhidKeyboard = nil
    screenStatePoller?.invalidate()
    screenStatePoller = nil
    if let monitor = mouseMonitor {
      NSEvent.removeMonitor(monitor)
      mouseMonitor = nil
    }
    chromeHideTimer?.invalidate()
    chromeHideTimer = nil
    clipboardBridge?.stop()
    clipboardBridge = nil
    Task {
      if recorder.isRecording {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
          recorder.stop { _ in cont.resume() }
        }
      }
      // Restore screen power before tearing down so we don't leave the device
      // dark after disconnect. Use setScreenPowerMode(NORMAL) for a clean wake.
      if autoScreenOffEnabled || isScreenOff, let writer = await session.control {
        try? await writer.send(.setScreenPowerMode(2))  // NORMAL — restore full power
      }
      if let serial = deviceSerial {
        await SessionCoordinator.shared.restoreOnScreenKeyboard(serial: serial, endedMirror: self)
      }
      // Restore device media volume if we muted it for "mac" audio mode.
      if let serial = deviceSerial, let vol = savedDeviceVolume {
        try? await adb.shell("media volume --stream 3 --set \(vol)", serial: serial)
        savedDeviceVolume = nil
      }
      await session.stop()
    }
  }

  // MARK: bind

  func bindControl() async {
    guard let writer = await session.control else { return }
    let reader = await session.deviceMessageReader
    let initialSize = CGSize(
      width: Int(await session.dimensions.width),
      height: Int(await session.dimensions.height)
    )

    // Apply user preferences from Settings → Mirror.
    let defaults = UserDefaults.standard
    let clipboardOn = defaults.object(forKey: "mirror.clipboardSync") as? Bool ?? true
    // Default ON — saves the phone from rendering its own panel + the mirror
    // simultaneously, which is the dominant heat source.
    let autoScreenOff = defaults.object(forKey: "mirror.autoScreenOff") as? Bool ?? true

    await MainActor.run {
      self.autoScreenOffEnabled = autoScreenOff
      self.titlebarControls?.setPhoneScreenOff(autoScreenOff)
      self.eventView.controlSink = { msg in
        Task { try? await writer.send(msg) }
      }
      // A restart brings a new control channel; retire the old bridge first.
      self.clipboardBridge?.stop()
      self.clipboardBridge = nil
      if let reader {
        let bridge = ClipboardBridge(writer: writer, reader: reader)
        bridge.enabled = clipboardOn
        bridge.start()
        self.clipboardBridge = bridge
      }
      self.applyDimensions(initialSize)
      self.window?.toolbar?.validateVisibleItems()
    }

    // Privacy preference — black out the device screen right after the first
    // frame so we don't surprise the user by displaying their lock screen.
    // Use setScreenPowerMode(0) to keep the virtual display rendering so the
    // Mac mirror stays alive while the phone panel is dark.
    // Skipped on session restart — the window already has its real screen state.
    if !isRestarting, autoScreenOff {
      try? await writer.send(.setScreenPowerMode(0))  // OFF — panel dark, display still rendering
      await MainActor.run {
        self.isScreenOff = true
        self.window?.toolbar?.validateVisibleItems()
      }
    }

    // Start polling the device's real screen state so the UI stays in sync
    // even when the user unlocks the phone manually.
    startScreenStatePoller()

    // Lay out Back / Home / Recents the way the phone's own navigation bar does.
    if let serial = deviceSerial {
      let lines = ((try? await adb.shell(
        "settings get global navigationbar_key_order; getprop ro.product.manufacturer", serial: serial
      )) ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      let order = lines.first ?? ""
      let isSamsung = lines.dropFirst().first?.lowercased() == "samsung"
      let backFirst = order == "1" || (order != "0" && !isSamsung)
      await MainActor.run { self.titlebarControls?.setNavigationOrder(backFirst: backFirst) }
    }

    // Apply the audio-output mode chosen in Settings.  When "mac" is active we
    // save the phone's current media volume and mute it so audio only plays
    // from the Mac (no double-sound).  Restored on disconnect / mode change.
    // Skipped on session restart — the mode was already applied before restart.
    if !isRestarting {
      await MainActor.run { self.applyAudioOutput(self.audioOutput) }
    }
    isRestarting = false

    // Wake screen on reconnect if already off — prevents deep sleep from re-applying screen-off
    if !isRestarting, autoScreenOff {
      let alreadyOff = await queryDeviceScreenOff(serial: deviceSerial ?? "")
      if alreadyOff { try? await writer.send(.setScreenPowerMode(2)); await MainActor.run { self.isScreenOff = false } }
      else { try? await writer.send(.setScreenPowerMode(0)); await MainActor.run { self.isScreenOff = true } }
    }

    // UHID keyboard — create after control channel is fully settled
    try? await Task.sleep(nanoseconds: 300_000_000)
    let km = UHIDKeyboardManager { [weak writer] msg in Task { try? await writer?.send(msg) } }
    await MainActor.run { self.uhidKeyboard = km; self.eventView.uhidKeyboard = km; km.create() }
  }

  // MARK: actions (wired from the title bar, More menu, Device menu, keyboard)

  /// Saves to the Desktop. A quick white flash on the phone screen confirms
  /// it, instead of a Finder window popping up every time.
  @objc func takeScreenshot() {
    guard let buffer = renderer.lastPixelBuffer else { return }
    let url = ScreenshotLocation.newFileURL(source: deviceDisplayName)
    do {
      try Screenshotter.savePNG(pixelBuffer: buffer, to: url)
      flashScreen()
    } catch {
      showAlert(error)
    }
  }

  private func flashScreen() {
    guard let screen = screenView else { return }
    let flash = NSView(frame: screen.bounds)
    flash.autoresizingMask = [.width, .height]
    flash.wantsLayer = true
    flash.layer?.backgroundColor = NSColor.white.cgColor
    flash.alphaValue = 0.7
    screen.addSubview(flash)
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.35
      flash.animator().alphaValue = 0
    }, completionHandler: { flash.removeFromSuperview() })
  }

  @objc func toggleRecord() {
    if recorder.isRecording {
      recorder.stop { [weak self] url in
        Task { @MainActor in
          self?.isRecording = false
          self?.titlebarControls?.setRecording(false)
          if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
      }
    } else {
      guard currentDeviceSize.width > 0 else { return }
      let dir = movieRoot()
      let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
      let url = dir.appendingPathComponent("Recording-\(stamp).mp4")
      do {
        try recorder.start(outputURL: url, size: currentDeviceSize)
        isRecording = true
        titlebarControls?.setRecording(true)
          } catch {
        showAlert(error)
      }
    }
  }

  @objc func togglePin() {
    isPinned.toggle()
    window?.level = isPinned ? .floating : .normal
  }

  @objc func sendBack() {
    Task {
      if let writer = await session.control {
        try? await writer.send(.backOrScreenOn(action: .down))
        try? await writer.send(.backOrScreenOn(action: .up))
      }
    }
  }

  @objc func sendHome() {
    sendKey(action: .down, code: 3)   // KEYCODE_HOME
    sendKey(action: .up, code: 3)
  }

  @objc func sendRecents() {
    sendKey(action: .down, code: 187) // KEYCODE_APP_SWITCH
    sendKey(action: .up, code: 187)
  }

  @objc func rotateDevice() {
    Task {
      if let writer = await session.control {
        try? await writer.send(.rotateDevice())
      }
    }
  }

  // MARK: live settings — SessionCoordinator calls these when Settings change

  func applyClipboardSync(_ on: Bool) {
    clipboardBridge?.enabled = on
  }

  /// Settings › Turn off phone screen while mirroring. On keeps the panel dark
  /// (the poller re-darkens it if the phone lights up); off lights it now.
  func applyPhoneScreenOff(_ on: Bool) {
    autoScreenOffEnabled = on
    isScreenOff = on
    titlebarControls?.setPhoneScreenOff(on)
    Task {
      if let writer = await session.control {
        // 0 = panel off (the display keeps rendering for the mirror), 2 = normal
        try? await writer.send(.setScreenPowerMode(on ? 0 : 2))
      }
    }
  }

  /// After a restart for a new audio output, mute or restore the phone side.
  func refreshAudioOutput() {
    applyAudioOutput(audioOutput)
  }

  /// Apply an audio-output mode to both the Mac-side renderer and the device.
  /// - `"mac"`:   Mac plays audio, device muted (avoid double sound)
  /// - `"phone"`: Device plays audio, Mac renderer paused
  /// - `"none"`:  Everything silent
  private func applyAudioOutput(_ mode: String) {
    // 1. Mac-side renderer
    switch mode {
    case "mac":   session.resumeAudio()
    default:      session.pauseAudio()
    }

    // 2. Device-side volume — only touch ADB when the session is live.
    guard let serial = deviceSerial else { return }
    Task {
      switch mode {
      case "mac":
        // Save current volume (first time) then mute so we don't get
        // duplicate audio from both speakers.
        if savedDeviceVolume == nil {
          savedDeviceVolume = await fetchDeviceVolume(serial: serial)
        }
        await setDeviceVolume(serial: serial, level: 0)

      case "phone":
        // Restore the original device volume.
        let level = savedDeviceVolume ?? 7
        await setDeviceVolume(serial: serial, level: level)
        savedDeviceVolume = nil

      case "none":
        if savedDeviceVolume == nil {
          savedDeviceVolume = await fetchDeviceVolume(serial: serial)
        }
        await setDeviceVolume(serial: serial, level: 0)

      default: break
      }
    }
  }

  // MARK: ADB volume helpers

  private func fetchDeviceVolume(serial: String) async -> Int? {
    do {
      let out = try await adb.shell("media volume --stream 3 --get", serial: serial)
      // "Volume is 7" or similar
      if let r = out.range(of: #"(\d+)"#, options: .regularExpression) {
        return Int(out[r].filter(\.isNumber))
      }
    } catch {}
    return nil
  }

  private func setDeviceVolume(serial: String, level: Int) async {
    do {
      _ = try await adb.shell("media volume --stream 3 --set \(level)", serial: serial)
    } catch {}
  }

  // MARK: screen-state poller

  /// Poll the phone's real screen state via ADB so `isScreenOff` (and therefore
  /// the Sleep/Wake button label) always reflects reality — even when the user
  /// unlocks the device manually.
  private func startScreenStatePoller() {
    screenStatePoller?.invalidate()
    screenStatePoller = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      guard let self, let serial = self.deviceSerial else { return }
      Task.detached { [weak self] in
        guard let self else { return }
        let actuallyOff = await self.queryDeviceScreenOff(serial: serial)
        let wantsAutoOff = await self.autoScreenOffEnabled
        await MainActor.run {
          let changed = self.isScreenOff != actuallyOff
          if changed {
            self.isScreenOff = actuallyOff
            self.window?.toolbar?.validateVisibleItems()
          }
          // If autoScreenOff is on and the user just unlocked the phone,
          // re-apply screen-off so the phone doesn't stay lit.
          if wantsAutoOff, !actuallyOff {
            Task {
              if let writer = await self.session.control {
                try? await writer.send(.setScreenPowerMode(0))
              }
            }
          }
        }
      }
    }
  }

  /// Returns `true` when the device display is off / dozing.
  private func queryDeviceScreenOff(serial: String) async -> Bool {
    do {
      let out = try await adb.shell("dumpsys power", serial: serial)
      // mWakefulness: Awake | Asleep | Doze | DozeSuspend
      if let range = out.range(of: "mWakefulness=") {
        let value = out[range.upperBound...].prefix { $0.isLetter }
        return value != "Awake"
      }
    } catch {
      // ADB unavailable or device disconnected — keep current state.
    }
    return isScreenOff
  }

  @objc func openFiles() {
    guard let device = currentDevice else { return }
    SessionCoordinator.shared.openFiles(for: device)
  }

  @objc func openDesktop() {
    guard let device = currentDevice else { return }
    Task { await SessionCoordinator.shared.openDesktop(for: device) }
  }

  /// The monitor's entry carries the phone's own name; the stream only knows the model.
  private var currentDevice: Device? {
    guard let serial = deviceSerial else { return nil }
    return SessionCoordinator.shared.monitor?.devices.first { $0.id == serial }
      ?? Device(id: serial, model: session.deviceName, androidSDK: 34, state: .online)
  }

  private func sendKey(action: KeyEventAction, code: Int32) {
    Task {
      if let writer = await session.control {
        try? await writer.send(.keycode(code, action: action))
      }
    }
  }

  // MARK: more menu — native NSMenu so toggles show checkmarks and choices
  // read as choices; rebuilt on every open so state is always current.

  private var isMoreMenuOpen = false

  private func showMoreMenu(anchor: NSView) {
    guard !isMoreMenuOpen else { return }
    let menu = makeMoreMenu()
    setChrome(revealed: true)
    chromeHideTimer?.invalidate()
    chromeHideTimer = nil
    isMoreMenuOpen = true
    let y = anchor.isFlipped ? anchor.bounds.maxY + 6 : -6
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: anchor)
    isMoreMenuOpen = false
    scheduleHideChrome()
  }

  /// Things you do to this phone or window. Preferences (quality, sound,
  /// phone screen, clipboard) live only in Settings, which applies them live.
  private func makeMoreMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let showsNav = Self.showsNavigationButtons
    menu.addItem(ActionMenuItem(
      showsNav ? String(localized: "Hide Navigation Buttons") : String(localized: "Show Navigation Buttons"),
      symbol: "chevron.left.chevron.right"
    ) { SessionCoordinator.shared.setNavigationButtonsVisible(!showsNav) })
    menu.addItem(ActionMenuItem(String(localized: "Keep Window on Top"), symbol: "pin", state: isPinned ? .on : .off) { [weak self] in
      self?.togglePin()
    })
    menu.addItem(.separator())

    menu.addItem(ActionMenuItem(String(localized: "Files…"), symbol: "folder") { [weak self] in
      self?.openFiles()
    })
    menu.addItem(ActionMenuItem(String(localized: "Desktop Mode…"), symbol: "display") { [weak self] in
      self?.openDesktop()
    })
    menu.addItem(.separator())

    let settings = MirrorShortcut.settings
    menu.addItem(ActionMenuItem(String(localized: "Mirroring Settings…"), symbol: "gearshape",
                                key: settings.key, modifiers: settings.modifiers) {
      SettingsLauncher.open(tab: "mirror")
    })
    return menu
  }

  // MARK: navigation buttons

  /// Off by default — Back/Home/Recents are also on ⌘[ / ⌘1 / ⌘2.
  static var showsNavigationButtons: Bool {
    UserDefaults.standard.bool(forKey: "mirror.showNavigationButtons")
  }

  func applyNavigationButtonsVisible(_ visible: Bool) {
    titlebarControls?.setNavigationVisible(visible)
    guard let window else { return }
    let aspect = window.contentAspectRatio
    let minimum = minimumContentSize(aspect: aspect)
    window.contentMinSize = minimum
    // Grow if the wider title bar would now run into the traffic lights.
    let content = window.contentRect(forFrameRect: window.frame)
    if content.width < minimum.width {
      var grown = content
      grown.size = minimum
      grown.origin.x = content.maxX - minimum.width
      grown.origin.y = content.maxY - minimum.height
      window.setFrame(window.frameRect(forContentRect: grown), display: true)
    }
  }

  /// Wide enough for the traffic lights plus the title-bar capsules.
  private func minimumContentSize(aspect: NSSize) -> NSSize {
    titlebarControls?.layoutSubtreeIfNeeded()
    let controls = titlebarControls?.fittingSize.width ?? 0
    let width = max(290, (controls + 96).rounded())
    return NSSize(width: width, height: (width * aspect.height / aspect.width).rounded())
  }

  // MARK: chrome reveal — iPhone-Mirroring style

  private func handleMouseMoved(_ event: NSEvent) {
    guard let window = self.window else { return }
    let loc = event.locationInWindow
    let h = window.frame.height
    // Top ~80pt reveals chrome immediately; anywhere else inside the window
    // just keeps the existing hide timer running.
    if loc.y > h - 80 {
      setChrome(revealed: true)
    }
    scheduleHideChrome()
  }

  private func setChrome(revealed: Bool, animated: Bool = true) {
    var revealed = revealed
    #if DEBUG
    if UserDefaults.standard.bool(forKey: "DMChromeVisible") { revealed = true }
    #endif
    chromeHideTimer?.invalidate()
    chromeHideTimer = nil
    if chromeRevealed == revealed { return }
    chromeRevealed = revealed
    guard let window else { return }
    let alpha: CGFloat = revealed ? 1.0 : 0.0
    let buttons: [NSButton?] = [
      window.standardWindowButton(.closeButton),
      window.standardWindowButton(.miniaturizeButton),
      window.standardWindowButton(.zoomButton),
    ]
    // The window is transparent around the bezel, so its shadow follows
    // whatever is drawn; recompute it or a hidden capsule leaves an outline.
    if animated {
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.18
        buttons.forEach { $0?.animator().alphaValue = alpha }
        titlebarControls?.animator().alphaValue = alpha
      }, completionHandler: { [weak window] in
        window?.invalidateShadow()
      })
    } else {
      buttons.forEach { $0?.alphaValue = alpha }
      titlebarControls?.alphaValue = alpha
      window.invalidateShadow()
    }
  }

  private func scheduleHideChrome() {
    // Don't hide under an open More menu — showMoreMenu re-arms on close.
    if isMoreMenuOpen { return }
    chromeHideTimer?.invalidate()
    // Stays visible 2s after the last cursor activity. Any mouseMoved /
    // mouseDown / scroll resets this timer (see mouseMonitor in init), so as
    // long as the user is interacting, chrome stays put.
    chromeHideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.setChrome(revealed: false) }
    }
  }

  // MARK: window adapt

  private func applyDimensions(_ size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    let changed = currentDeviceSize != size
    currentDeviceSize = size
    eventView.deviceDimensions = size

    guard let window = self.window else { return }
    // contentAspectRatio is set on the *window content rect*, which is the
    // device area + 2*bezelInset on each side + chromeStrip at the top.
    let aspect = aspectRatio(for: size)
    window.contentAspectRatio = aspect
    // Narrower than this and the title-bar capsules run into the traffic lights.
    window.contentMinSize = minimumContentSize(aspect: aspect)

    if !hasSetInitialFrame {
      hasSetInitialFrame = true
      if !restoreWindowFrame() {
        setInitialFrame(deviceSize: size, window: window)
      }
      return
    }
    guard changed else { return }

    let oldFrame = window.frame
    let oldContent = window.contentRect(forFrameRect: oldFrame).size
    let oldArea = max(1, oldContent.width * oldContent.height)
    let scale = sqrt(oldArea / (aspect.width * aspect.height))
    let newContent = CGSize(width: aspect.width * scale, height: aspect.height * scale)
    let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: newContent))
    var finalFrame = newFrame
    finalFrame.origin = CGPoint(
      x: oldFrame.midX - finalFrame.width / 2,
      y: oldFrame.midY - finalFrame.height / 2
    )
    // `animate: true` makes NSWindow interpolate the frame, but during that
    // animation the rounded-bezel mask and the titlebar layer fall briefly
    // out of sync — you see a black square flash. Instant resize avoids it.
    window.setFrame(finalFrame, display: true, animate: false)
    window.invalidateShadow()
  }

  private func setInitialFrame(deviceSize: CGSize, window: NSWindow) {
    window.setFrame(PhoneWindowSizing.defaultFrame(aspect: window.contentAspectRatio, in: window, screen: window.screen), display: true)
  }

  private func saveWindowFrame() {
    // Before the first video frame the window still has its placeholder size.
    guard hasSetInitialFrame, let f = window?.frame else { return }
    MirrorFramePersistence.save(f, serial: deviceSerial)
  }

  /// Put the phone where it last was on screen: the shared last frame (also
  /// written by the Connect window) unless another Mirror already sits there,
  /// then this device's own frame. Width follows the current device aspect.
  @discardableResult
  private func restoreWindowFrame() -> Bool {
    guard let win = self.window else { return false }
    let othersOpen = NSApp.windows.contains {
      $0 !== win && $0.isVisible && $0.windowController is MirrorWindowController
    }
    let device = deviceSerial.flatMap(MirrorFramePersistence.frame(serial:))
    let candidates = othersOpen ? [device] : [MirrorFramePersistence.lastFrame(), device]
    guard let f = candidates.compactMap({ $0 }).first(where: { r in
      NSScreen.screens.contains { $0.visibleFrame.intersects(r) }
    }) else { return false }
    win.setFrame(MirrorFramePersistence.fit(f, aspect: win.contentAspectRatio, in: win), display: true)
    win.invalidateShadow()
    return true
  }

  private func aspectRatio(for deviceSize: CGSize) -> NSSize {
    NSSize(
      width:  deviceSize.width  + 2 * Self.bezelInset,
      height: deviceSize.height + Self.chromeStrip + 2 * Self.bezelInset
    )
  }

  // MARK: helpers


  private func movieRoot() -> URL {
    let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
    let dir = base.appendingPathComponent("aPhone Mirroring").appendingPathComponent(deviceDisplayName)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func showAlert(_ error: Error) {
    let alert = NSAlert(error: error)
    if let window { alert.beginSheetModal(for: window) }
    else { alert.runModal() }
  }
}

// MARK: PhoneBezelView — black rounded shell hosting the Metal mirror view

final class PhoneBezelView: NSView {
  init(content: NSView, inset: CGFloat, cornerRadius: CGFloat) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.cornerRadius = cornerRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true

    addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
      content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
      content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }
}
