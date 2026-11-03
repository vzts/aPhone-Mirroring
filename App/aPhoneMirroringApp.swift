import SwiftUI
import AppKit
import Combine
import os
import DeviceDiscovery
import SharedModels

@main
struct APhoneMirroringApp: App {
  init() {
    setvbuf(stdout, nil, _IONBF, 0)   // log to /tmp/aphonemirroring.log without buffering
    setvbuf(stderr, nil, _IONBF, 0)
  }

  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

  var body: some Scene {
    // No main window: the phone-shaped Connect / Mirror windows are the app.
    // Everything else lives in the menu bar extra, the Device menu, and Settings.
    MenuBarExtra(AppInfo.name, systemImage: "iphone.gen3", isInserted: $showMenuBarIcon) {
      MenuBarContent()
        .environmentObject(appDelegate.monitor)
    }
    .menuBarExtraStyle(.window)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          NSWorkspace.shared.open(AppInfo.repository.appendingPathComponent("releases/latest"))
        }
      }
      CommandGroup(before: .toolbar) {
        ViewCommands()
      }
      CommandMenu("Device") {
        DeviceCommands()
      }
      CommandGroup(replacing: .help) {
        Button("GitHub Repository") {
          NSWorkspace.shared.open(AppInfo.repository)
        }
      }
    }

    Settings {
      SettingsView()
        .environmentObject(appDelegate.monitor)
    }
  }
}

/// Opens Settings from AppKit code (the More menu), optionally on a tab.
@MainActor
enum SettingsLauncher {
  static func open(tab: String? = nil) {
    if let tab { UserDefaults.standard.set(tab, forKey: "settings.tab") }
    NSApp.activate(ignoringOtherApps: true)
    // SwiftUI's Settings scene has no AppKit entry point; run the app menu's
    // own "Settings…" item, exactly as if it were clicked.
    guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
          let index = appMenu.items.firstIndex(where: {
            $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
          }) else { return }
    appMenu.performActionForItem(at: index)
  }
}

/// Device menu — acts on the frontmost Mirror window. Shortcuts come from
/// `MirrorShortcut`, shared with the More menu and button tooltips.
private struct DeviceCommands: View {
  @AppStorage("mirror.autoScreenOff") private var phoneScreenOff = true

  var body: some View {
    Button("Back") { MirrorWindowController.key?.sendBack() }
      .shortcut(.back)
    Button("Home") { MirrorWindowController.key?.sendHome() }
      .shortcut(.home)
    Button("Recents") { MirrorWindowController.key?.sendRecents() }
      .shortcut(.recents)
    Divider()
    Button("Take Screenshot") { MirrorWindowController.key?.takeScreenshot() }
      .shortcut(.screenshot)
    Button("Start or Stop Recording") { MirrorWindowController.key?.toggleRecord() }
      .shortcut(.record)
    Button("Rotate Screen") { MirrorWindowController.key?.rotateDevice() }
      .shortcut(.rotate)
    Toggle("Turn off phone screen while mirroring", isOn: Binding(
      get: { phoneScreenOff },
      set: { SessionCoordinator.shared.setPhoneScreenOff($0) }
    ))
    .shortcut(.phoneScreen)
    Divider()
    Button("Refresh Active Display") {
      guard let controller = MirrorWindowController.key, let serial = controller.deviceSerial else { return }
      Task { await SessionCoordinator.shared.refreshActiveDisplay(for: Device(id: serial, state: .online)) }
    }
    .shortcut(.refreshDisplay)
    Divider()
    Button("Connect a Phone…") { SessionCoordinator.shared.showConnectWindow() }
  }
}

/// View menu: the mirror window's navigation buttons.
private struct ViewCommands: View {
  @AppStorage("mirror.showNavigationButtons") private var showsNavigation = false

  var body: some View {
    Button(showsNavigation ? LocalizedStringKey("Hide Navigation Buttons") : LocalizedStringKey("Show Navigation Buttons")) {
      SessionCoordinator.shared.setNavigationButtonsVisible(!showsNavigation)
    }
  }
}

private extension View {
  func shortcut(_ s: MirrorShortcut) -> some View {
    var modifiers: EventModifiers = []
    if s.modifiers.contains(.command) { modifiers.insert(.command) }
    if s.modifiers.contains(.shift) { modifiers.insert(.shift) }
    if s.modifiers.contains(.option) { modifiers.insert(.option) }
    if s.modifiers.contains(.control) { modifiers.insert(.control) }
    return keyboardShortcut(KeyEquivalent(Character(s.key)), modifiers: modifiers)
  }
}

/// Lifecycle owner now that there is no Window scene to hang `.onAppear` off.
/// Holds the singleton `DeviceMonitor`, wires Combine → SessionCoordinator
/// auto-mirror, and intercepts Quit + Dock-icon-reopen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
  let monitor: DeviceMonitor = DeviceMonitor(
    adbBinary: Bundle.main.url(forResource: "adb", withExtension: nil)
  )
  private var deviceCancellable: AnyCancellable?

  func applicationDidFinishLaunching(_ notification: Notification) {
    AppInfo.migrateSettingsFromDroidMirroring()
    AppLanguage.captureLaunchState()
    SessionCoordinator.shared.monitor = monitor
    // A phone on USB and Wi-Fi at once is listed by the connection it was mirrored over.
    monitor.isPreferredSerial = { SessionCoordinator.shared.isTrusted($0) }
    // Keep a Dock icon — without it, users have no visible signal that the
    // app is running until they spot the menu bar item. The Dock icon also
    // gives us a proper "click to reopen" target.
    NSApp.setActivationPolicy(.regular)

    monitor.start()
    Task { [monitor] in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      // CRITICAL: only sweep if we haven't already auto-mirrored. Otherwise
      // we'd pkill the scrcpy-server we just launched — symptoms are dead
      // touch input and frozen IME in the new Mirror window.
      guard !SessionCoordinator.shared.hasActiveSession else { return }
      await monitor.sweepStaleScrcpyServers()
    }

    #if DEBUG
    DebugScreens.showRequested(monitor: monitor)
    #endif

    deviceCancellable = monitor.$devices
      .removeDuplicates()
      .sink { devices in
        Task { @MainActor in
          SessionCoordinator.shared.autoMirrorIfNeeded(devices: devices)
        }
      }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Nothing to restore on a phone: quit right away instead of waiting.
    guard SessionCoordinator.shared.needsShutdown else { return .terminateNow }
    Task { @MainActor in
      await SessionCoordinator.shared.shutdownEverything()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Dock icon clicked while nothing is on screen. We have three live
  /// possibilities:
  ///   - device online → open Mirror for it
  ///   - no device online → open the Pair Wireless Device window
  ///   - mirror window exists but is minimised → bring it forward
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if hasVisibleWindows { return true }

    // First: surface an existing minimised Mirror or Files window if any.
    if let mirror = NSApp.windows.first(where: { $0.windowController is MirrorWindowController }) {
      NSApp.activate(ignoringOtherApps: true)
      mirror.makeKeyAndOrderFront(nil)
      return true
    }

    // Online device with no window → re-open Mirror for it.
    if let device = monitor.devices.first(where: { $0.state == .online }) {
      Task { @MainActor in await SessionCoordinator.shared.startMirror(for: device) }
      return true
    }

    // Nothing connected → the phone-shaped Connect window.
    SessionCoordinator.shared.showConnectWindow()
    return true
  }
}

#if DEBUG
/// `-DMDebugShow connect,settings,menubar` opens screens at launch so they can
/// be captured and checked without clicking through the app.
@MainActor
enum DebugScreens {
  private static var windows: [NSWindow] = []

  static func showRequested(monitor: DeviceMonitor) {
    let requested = Set((UserDefaults.standard.string(forKey: "DMDebugShow") ?? "").split(separator: ",").map(String.init))
    if requested.contains("connect") {
      // After auto-mirror has had its chance, so the window isn't handed off.
      DispatchQueue.main.asyncAfter(deadline: .now() + 6) { SessionCoordinator.shared.showConnectWindow() }
    }
    if let code = requested.first(where: { $0.hasPrefix("relaunch-") })?.dropFirst("relaunch-".count) {
      // Same path as Settings › Language › Restart Now.
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        AppLanguage.override = String(code)
        AppLanguage.relaunch()
      }
    }
    if requested.contains("files") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        if let device = monitor.devices.first(where: { $0.state == .online }) {
          SessionCoordinator.shared.openFiles(for: device)
        }
      }
    }
    if requested.contains("settings-later") {
      // Same path as More › Mirroring Settings…, after launch has settled.
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { SettingsLauncher.open(tab: "mirror") }
    }
    if requested.contains("settings") {
      let opener = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [], backing: .buffered, defer: false)
      opener.contentView = NSHostingView(rootView: SettingsOpener())
      opener.orderFrontRegardless()
      windows.append(opener)
    }
    if requested.contains("menubar") {
      let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
      window.title = "Menu bar preview"
      window.contentView = NSHostingView(rootView: MenuBarContent().environmentObject(monitor))
      window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: 300, height: 300))
      window.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.visibleFrame.maxY ?? 800) - 40))
      window.orderFrontRegardless()
      windows.append(window)
    }
  }
}

private struct SettingsOpener: View {
  @Environment(\.openSettings) private var openSettings
  var body: some View { Color.clear.onAppear { openSettings() } }
}
#endif
