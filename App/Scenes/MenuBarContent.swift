import SwiftUI
import AppKit
import DeviceDiscovery
import SharedModels

/// Menu bar extra: who's connected, one click to mirror, and the app's few
/// global actions. Laid out like Control Center modules so it reads as part
/// of macOS rather than a custom popover.
struct MenuBarContent: View {
  @EnvironmentObject var monitor: DeviceMonitor
  @Environment(\.openSettings) private var openSettings
  @ObservedObject private var updates = UpdateChecker.shared

  private var online: [Device] { monitor.devices.filter { $0.state == .online } }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)

      Group {
        if online.isEmpty {
          emptyState
        } else {
          VStack(spacing: 6) {
            ForEach(online) { MenuDeviceCard(device: $0) }
          }
        }
      }
      .padding(.horizontal, 10)

      Divider().padding(.vertical, 8).padding(.horizontal, 14)

      VStack(spacing: 0) {
        // A newer release the user hasn't skipped: offered here between checks.
        if let pending = updates.pending {
          MenuRow(title: "Update to \(pending.version?.description ?? pending.tag)…", symbol: "arrow.down.circle") {
            UpdateChecker.shared.showPending()
          }
        }
        MenuRow(title: "Connect a Phone…", symbol: "plus.circle") {
          SessionCoordinator.shared.showConnectWindow()
        }
        MenuRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") {
          NSApp.activate(ignoringOtherApps: true)
          openSettings()
        }
        MenuRow(title: "Quit \(AppInfo.name)", symbol: "power", shortcut: "⌘Q") {
          NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
      }
      .padding(.horizontal, 6)
      .padding(.bottom, 8)
    }
    .frame(width: 300)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 30, height: 30)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: AppInfo.name).font(.headline)
        Text(statusText).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  private var statusText: String {
    switch online.count {
    case 0: return String(localized: "No phone connected")
    case 1: return String(localized: "1 phone connected")
    default: return String(localized: "\(online.count) phones connected")
    }
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "iphone.gen3.slash")
        .font(.system(size: 26))
        .foregroundStyle(.secondary)
      Text("Turn on Wireless debugging on your phone, or plug it in with USB debugging on.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Button("Connect a Phone…") { SessionCoordinator.shared.showConnectWindow() }
        .primaryButtonStyle()
        .controlSize(.regular)
    }
    .padding(16)
    .frame(maxWidth: .infinity)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

private struct MenuDeviceCard: View {
  let device: Device

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "iphone.gen3")
        .font(.title2)
        .foregroundStyle(.tint)
        .frame(width: 26)
      VStack(alignment: .leading, spacing: 2) {
        Text(device.displayName)
          .font(.callout.weight(.semibold))
          .lineLimit(1)
        HStack(spacing: 4) {
          Image(systemName: device.transport == .usb ? "cable.connector" : "wifi")
          Text(androidVersionName(sdk: device.androidSDK))
        }
        .lineLimit(1)
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 6)
      Button("Mirror") {
        Task { await SessionCoordinator.shared.startMirror(for: device) }
      }
      .primaryButtonStyle()
      .controlSize(.small)
      Menu {
        Button("Files…") { SessionCoordinator.shared.openFiles(for: device) }
        if device.supportsFreeform {
          Button("Desktop Mode…") { Task { await SessionCoordinator.shared.openDesktop(for: device) } }
        }
        if device.transport == .wifi {
          Divider()
          Button("Disconnect") { Task { await SessionCoordinator.shared.disconnectWirelessDevice(for: device) } }
        }
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(.borderless)
      .fixedSize()
      .help(Text("More"))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .contentShape(Rectangle())
    .help(Text(verbatim: "\(device.modelName) · \(device.id)"))
    .onTapGesture(count: 2) { Task { await SessionCoordinator.shared.startMirror(for: device) } }
  }
}

/// Full-width row with a hover highlight, like a native menu item.
private struct MenuRow: View {
  let title: LocalizedStringKey
  let symbol: String
  var shortcut: String? = nil
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: symbol)
          .frame(width: 18)
          .foregroundStyle(.secondary)
        Text(title)
        Spacer()
        if let shortcut {
          Text(verbatim: shortcut).foregroundStyle(.tertiary)
        }
      }
      .font(.callout)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(hovering ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}
