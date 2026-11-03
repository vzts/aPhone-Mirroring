import SwiftUI
import AppKit
import Combine
import os
import DeviceDiscovery
import SharedModels

@main
struct DroidMirroringApp: App {
  init() {
    setvbuf(stdout, nil, _IONBF, 0)   // log to /tmp/droidmirroring.log without buffering
    setvbuf(stderr, nil, _IONBF, 0)
  }

  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

  var body: some Scene {
    // No main window: the phone-shaped Connect / Mirror windows are the app.
    // Everything else lives in the menu bar extra, the Device menu, and Settings.
    MenuBarExtra("Droid Mirroring", systemImage: "iphone.gen3", isInserted: $showMenuBarIcon) {
      MenuBarContent()
        .environmentObject(appDelegate.monitor)
    }
    .menuBarExtraStyle(.window)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          NSWorkspace.shared.open(URL(string: "https://github.com/matyle/droidMirroring-mac/releases/latest")!)
        }
      }
      CommandMenu("Device") {
        DeviceCommands()
      }
      CommandGroup(replacing: .help) {
        Button("Official Website") {
          NSWorkspace.shared.open(URL(string: "https://droidmirroring.pages.dev")!)
        }
        Button("GitHub Repository") {
          NSWorkspace.shared.open(URL(string: "https://github.com/matyle/droidMirroring-mac")!)
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

/// Device menu — acts on the frontmost Mirror window. Shortcuts follow
/// iPhone Mirroring where an equivalent exists (⌘1 Home, ⌘2 App Switcher).
private struct DeviceCommands: View {
  @AppStorage("mirror.autoScreenOff") private var phoneScreenOff = true

  var body: some View {
    Button("Back") { MirrorWindowController.key?.sendBack() }
      .keyboardShortcut("[", modifiers: .command)
    Button("Home") { MirrorWindowController.key?.sendHome() }
      .keyboardShortcut("1", modifiers: .command)
    Button("Recents") { MirrorWindowController.key?.sendRecents() }
      .keyboardShortcut("2", modifiers: .command)
    Divider()
    Button("Take Screenshot") { MirrorWindowController.key?.takeScreenshot() }
      .keyboardShortcut("s", modifiers: .command)
    Button("Start or Stop Recording") { MirrorWindowController.key?.toggleRecord() }
      .keyboardShortcut("r", modifiers: [.command, .shift])
    Button("Rotate Screen") { MirrorWindowController.key?.rotateDevice() }
    Toggle("Turn off phone screen while mirroring", isOn: Binding(
      get: { phoneScreenOff },
      set: { SessionCoordinator.shared.setPhoneScreenOff($0) }
    ))
    Divider()
    Button("Refresh Active Display") {
      guard let controller = MirrorWindowController.key, let serial = controller.deviceSerial else { return }
      Task { await SessionCoordinator.shared.refreshActiveDisplay(for: Device(id: serial, state: .online)) }
    }
    .keyboardShortcut("r", modifiers: .command)
    Divider()
    Button("Connect a Phone…") { SessionCoordinator.shared.showConnectWindow() }
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
    SessionCoordinator.shared.monitor = monitor
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
