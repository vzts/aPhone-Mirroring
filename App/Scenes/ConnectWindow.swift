import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import DeviceDiscovery
import SharedModels

/// The phone-shaped window shown when nothing is mirroring. It has the same
/// bezel and size as the Mirror window, so connecting feels like the phone
/// turning on rather than one window being swapped for another. The whole
/// connect flow (QR, pairing code, IP address, USB) happens inside it.
@MainActor
final class ConnectWindowController: NSWindowController {
  static let bezelInset: CGFloat = 8
  static let bezelCornerRadius: CGFloat = 34
  static let innerCornerRadius: CGFloat = 26
  static let chromeStrip: CGFloat = 32
  /// Typical modern phone panel; matches the Mirror window for most devices.
  static let defaultDevice = CGSize(width: 1080, height: 2340)

  let pairing = PairingModel()

  init(monitor: DeviceMonitor?) {
    let aspect = NSSize(
      width: Self.defaultDevice.width + 2 * Self.bezelInset,
      height: Self.defaultDevice.height + Self.chromeStrip + 2 * Self.bezelInset
    )
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 320, height: 680)),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = String(localized: "Connect your phone")
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = true
    window.contentAspectRatio = aspect
    window.contentMinSize = NSSize(width: 280, height: 280 * aspect.height / aspect.width)
    window.standardWindowButton(.zoomButton)?.isHidden = true

    let root = ConnectView(pairing: pairing, monitor: monitor ?? DeviceMonitor(adbBinary: nil))
    let hosting = NSHostingView(rootView: root)

    let screenClip = NSView()
    screenClip.wantsLayer = true
    screenClip.layer?.cornerRadius = Self.innerCornerRadius
    screenClip.layer?.cornerCurve = .continuous
    screenClip.layer?.masksToBounds = true
    screenClip.layer?.backgroundColor = NSColor.black.cgColor
    screenClip.addSubview(hosting)
    hosting.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: screenClip.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: screenClip.trailingAnchor),
      hosting.topAnchor.constraint(equalTo: screenClip.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: screenClip.bottomAnchor),
    ])

    let bezel = PhoneBezelView(content: screenClip, inset: Self.bezelInset, cornerRadius: Self.bezelCornerRadius)
    let container = NSView()
    container.wantsLayer = true
    container.addSubview(bezel)
    bezel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      bezel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      bezel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      bezel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      bezel.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.chromeStrip),
    ])
    window.contentView = container
    super.init(window: window)
    placeWindow(window, aspect: aspect)
    for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
      NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
        MainActor.assumeIsolated {
          if let frame = window?.frame { MirrorFramePersistence.save(frame, serial: nil) }
        }
      }
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func showWindow(_ sender: Any?) {
    pairing.start()
    super.showWindow(sender)
  }

  override func close() {
    pairing.stop()
    super.close()
  }

  /// Sit where the last Mirror window was, so the phone stays put on screen —
  /// unless a Mirror is open there now, then sit beside it.
  private func placeWindow(_ window: NSWindow, aspect: NSSize) {
    var frame: NSRect
    if let last = MirrorFramePersistence.lastFrame(),
       NSScreen.screens.contains(where: { $0.visibleFrame.intersects(last) }) {
      frame = MirrorFramePersistence.fit(last, aspect: aspect, in: window)
    } else {
      frame = PhoneWindowSizing.defaultFrame(aspect: aspect, in: window, screen: NSScreen.main)
    }
    let mirrors = NSApp.windows.filter { $0.isVisible && $0.windowController is MirrorWindowController }
    if let blocking = mirrors.first(where: { $0.frame.intersects(frame) }) {
      let visible = blocking.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
      let gap: CGFloat = 24
      let left = blocking.frame.minX - gap - frame.width
      let right = blocking.frame.maxX + gap
      frame.origin.x = left >= visible.minX ? left : min(right, visible.maxX - frame.width)
    }
    window.setFrame(frame, display: false)
  }
}

// MARK: - Content

private enum ConnectRoute: Hashable {
  case home
  case code(String?)   // preselected pairing endpoint id
  case manual
  case usb
}

struct ConnectView: View {
  @ObservedObject var pairing: PairingModel
  @ObservedObject var monitor: DeviceMonitor
  @State private var route: ConnectRoute = ConnectView.initialRoute
  @State private var autoOpenedCandidates: Set<String> = []

  private static var initialRoute: ConnectRoute {
    #if DEBUG
    switch UserDefaults.standard.string(forKey: "DMConnectRoute") {
    case "code": return .code(nil)
    case "manual": return .manual
    case "usb": return .usb
    default: break
    }
    #endif
    return .home
  }

  var body: some View {
    VStack(spacing: 0) {
      Group {
        if route == .home {
          // Whole screen when it fits, a denser one when it doesn't, scrolling
          // only as a last resort — the status line must never fall off.
          ViewThatFits(in: .vertical) {
            HomeScreen(pairing: pairing, monitor: monitor, density: .regular).modifier(ScreenPadding())
            HomeScreen(pairing: pairing, monitor: monitor, density: .compact).modifier(ScreenPadding())
            ScrollView(.vertical) {
              HomeScreen(pairing: pairing, monitor: monitor, density: .compact).modifier(ScreenPadding())
            }
            .scrollIndicators(.never)
          }
        } else {
          switch route {
          case .code(let preselected): CodeScreen(pairing: pairing, preselected: preselected, route: $route)
          case .manual: ManualScreen(pairing: pairing, route: $route)
          case .usb, .home: USBScreen(route: $route)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      if route == .home {
        OtherWaysMenu(pairing: pairing, route: $route)
          .padding(.top, 8)
          .padding(.bottom, 18)
      }
    }
    .background(ConnectBackground())
    .environment(\.colorScheme, .dark)
    .animation(.smooth(duration: 0.25), value: route)
    .onChange(of: pairing.codeCandidates.map(\.id)) { _, ids in
      // The phone just opened "Pair device with pairing code" — go straight to code entry.
      guard route == .home, let id = ids.first(where: { !autoOpenedCandidates.contains($0) }) else { return }
      autoOpenedCandidates.insert(id)
      pairing.clearStatus()
      route = .code(id)
    }
  }
}

private struct ScreenPadding: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 18)
      .padding(.top, 22)
      .padding(.bottom, 12)
      .frame(maxWidth: .infinity, alignment: .top)
  }
}

private enum HomeDensity { case regular, compact }

/// Sub-screen layout: content scrolls at the top, the action stays pinned at
/// the bottom where the home screen keeps its menu.
private struct RouteLayout<Content: View, Footer: View>: View {
  @ViewBuilder let content: Content
  @ViewBuilder let footer: Footer

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 18) { content }
          .modifier(ScreenPadding())
      }
      .scrollIndicators(.never)
      VStack(spacing: 12) { footer }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }
  }
}

private struct ConnectBackground: View {
  var body: some View {
    ZStack {
      LinearGradient(colors: [Color(white: 0.13), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
      RadialGradient(colors: [Color.accentColor.opacity(0.28), .clear], center: .top, startRadius: 0, endRadius: 320)
    }
  }
}

// MARK: Home — QR first

private struct HomeScreen: View {
  @ObservedObject var pairing: PairingModel
  @ObservedObject var monitor: DeviceMonitor
  let density: HomeDensity

  private var readyDevices: [Device] { monitor.devices.filter { $0.state == .online } }

  var body: some View {
    let regular = density == .regular
    // Centred between the top of the screen and the pinned menu; gaps inside
    // are fixed so the rhythm holds at any window size.
    VStack(spacing: 0) {
      Spacer(minLength: 4)
      VStack(spacing: 6) {
        if regular {
          Image(systemName: "iphone.gen3.radiowaves.left.and.right")
            .font(.system(size: 30, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tint)
            .padding(.bottom, 4)
        }
        Text("Connect your phone")
          .font(.title3.weight(.semibold))
        if regular {
          Text("Pair once over Wi-Fi. After that, it connects on its own.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer().frame(height: regular ? 24 : 16)
      VStack(spacing: 12) {
        if !readyDevices.isEmpty {
          ReadyDevicesCard(devices: readyDevices)
        }
        qrCard(regular: regular)
      }
      Spacer(minLength: 4)
    }
  }

  private func qrCard(regular: Bool) -> some View {
    let side: CGFloat = regular ? 140 : 104
    return VStack(spacing: 14) {
      QRCodeImage(payload: pairing.qrPayload)
        .frame(width: side, height: side)
        .padding(regular ? 10 : 8)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(Text("Pairing QR code"))
      VStack(alignment: .leading, spacing: 10) {
        StepRow(number: 1, text: "On your phone, open **Settings › Developer options › Wireless debugging**.")
        StepRow(number: 2, text: "Tap **Pair device with QR code** and scan this code.")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Divider().opacity(0.5)
      // The QR flow's own state, so it lives on the card rather than floating below.
      StatusLine(phase: pairing.phase, idleText: "Waiting for your phone…")
    }
    .padding(.horizontal, 14)
    .padding(.top, 16)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity)
    .glassPanel()
  }
}

/// Pinned under the scrolling content so it's reachable at any window size.
private struct OtherWaysMenu: View {
  @ObservedObject var pairing: PairingModel
  @Binding var route: ConnectRoute

  var body: some View {
    Menu {
      Button("Pair with a code instead") { pairing.clearStatus(); route = .code(nil) }
      Button("Enter an IP address") { pairing.clearStatus(); route = .manual }
      Divider()
      Button("Use a USB cable") { route = .usb }
      Divider()
      Button("New QR code") { pairing.regenerateQR() }
    } label: {
      Text("Other ways to connect")
    }
    .menuStyle(.button)
    .secondaryButtonStyle()
    .fixedSize()
  }
}

private struct ReadyDevicesCard: View {
  let devices: [Device]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Connected")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      ForEach(devices) { device in
        HStack(spacing: 10) {
          Image(systemName: device.transport == .usb ? "cable.connector" : "wifi")
            .foregroundStyle(.tint)
            .frame(width: 18)
          VStack(alignment: .leading, spacing: 1) {
            Text(device.displayName).font(.callout.weight(.medium))
            Text(androidVersionName(sdk: device.androidSDK)).font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          Button("Mirror") {
            Task { await SessionCoordinator.shared.startMirror(for: device) }
          }
          .primaryButtonStyle()
          .controlSize(.small)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassPanel()
  }
}

// MARK: Pairing code

private struct CodeScreen: View {
  @ObservedObject var pairing: PairingModel
  let preselected: String?
  @Binding var route: ConnectRoute
  @State private var selection: String?
  @State private var code = ""
  @FocusState private var codeFocused: Bool

  private var candidates: [WirelessEndpoint] { pairing.codeCandidates }
  private var selected: WirelessEndpoint? {
    candidates.first(where: { $0.id == selection }) ?? (candidates.count == 1 ? candidates.first : nil)
  }

  var body: some View {
    RouteLayout {
      BackButton { route = .home }
      ScreenTitle(title: "Enter pairing code", subtitle: "Type the 6-digit code shown on your phone.")

      if candidates.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Looking for your phone…").font(.callout).foregroundStyle(.secondary)
          }
          Text("On your phone: **Wireless debugging › Pair device with pairing code**.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
      } else {
        VStack(spacing: 6) {
          ForEach(candidates) { endpoint in
            EndpointRow(endpoint: endpoint, isSelected: selected?.id == endpoint.id) {
              selection = endpoint.id
            }
          }
        }
      }

      TextField("", text: $code, prompt: Text(verbatim: "000000"))
        .textFieldStyle(.plain)
        .font(.system(size: 30, weight: .semibold, design: .monospaced))
        .tracking(8)
        .multilineTextAlignment(.center)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .glassPanel(cornerRadius: 14)
        .focused($codeFocused)
        .onChange(of: code) { _, new in
          let digits = String(new.filter(\.isNumber).prefix(6))
          if digits != new { code = digits }
          if digits.count == 6 { submit() }
        }
        .onSubmit(submit)
        .accessibilityLabel(Text("Pairing Code"))
    } footer: {
      StatusLine(phase: pairing.phase, idleText: nil)
      Button(action: submit) {
        Text("Pair").frame(maxWidth: .infinity)
      }
      .primaryButtonStyle()
      .controlSize(.large)
      .disabled(selected == nil || code.count != 6 || pairing.phase.isWorking)
      .keyboardShortcut(.defaultAction)
    }
    .onAppear {
      selection = preselected
      codeFocused = true
    }
  }

  private func submit() {
    guard let endpoint = selected, code.count == 6, !pairing.phase.isWorking else { return }
    pairing.pair(endpoint, code: code)
  }
}

private struct EndpointRow: View {
  let endpoint: WirelessEndpoint
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: "iphone.gen3")
          .font(.title3)
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 1) {
          Text(endpoint.deviceSerialHint).font(.callout.weight(.medium))
          Text(verbatim: "\(endpoint.host):\(endpoint.port)")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .glassPanel(cornerRadius: 12)
  }
}

// MARK: Manual IP

private struct ManualScreen: View {
  @ObservedObject var pairing: PairingModel
  @Binding var route: ConnectRoute
  @State private var host = ""
  @State private var port = ""
  @State private var code = ""

  private var canSubmit: Bool {
    !host.isEmpty && Int(port) != nil && (code.isEmpty || code.count == 6) && !pairing.phase.isWorking
  }

  var body: some View {
    RouteLayout {
      BackButton { route = .home }
      ScreenTitle(
        title: "Connect by IP address",
        subtitle: "Use the address shown under Wireless debugging. To pair for the first time, use the address and code from Pair device with pairing code."
      )
      VStack(alignment: .leading, spacing: 12) {
        LabeledField(label: "IP address") {
          TextField("", text: $host, prompt: Text(verbatim: "192.168.0.10"))
        }
        LabeledField(label: "Port") {
          TextField("", text: $port, prompt: Text(verbatim: "37000"))
            .onChange(of: port) { _, new in port = String(new.filter(\.isNumber).prefix(5)) }
        }
        LabeledField(label: "Pairing code (first time only)") {
          TextField("", text: $code, prompt: Text(verbatim: "123456"))
            .onChange(of: code) { _, new in code = String(new.filter(\.isNumber).prefix(6)) }
        }
      }
    } footer: {
      StatusLine(phase: pairing.phase, idleText: nil)
      Button {
        guard let portNumber = Int(port) else { return }
        pairing.connectManually(host: host.trimmingCharacters(in: .whitespaces), port: portNumber, code: code)
      } label: {
        Text(code.isEmpty ? "Connect" : "Pair & Connect").frame(maxWidth: .infinity)
      }
      .primaryButtonStyle()
      .controlSize(.large)
      .disabled(!canSubmit)
      .keyboardShortcut(.defaultAction)
    }
  }
}

private struct LabeledField<Field: View>: View {
  let label: LocalizedStringKey
  @ViewBuilder let field: Field

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      field
        .textFieldStyle(.plain)
        .font(.body.monospaced())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassPanel(cornerRadius: 10)
    }
  }
}

// MARK: USB

private struct USBScreen: View {
  @Binding var route: ConnectRoute

  var body: some View {
    RouteLayout {
      BackButton { route = .home }
      ScreenTitle(title: "Connect with a USB cable", subtitle: "Turn on USB debugging once. After that, just plug in.")
      VStack(alignment: .leading, spacing: 12) {
        StepRow(number: 1, text: "On your phone, open **Settings › About phone** and tap **Build number** 7 times.")
        StepRow(number: 2, text: "Go back to **Settings › Developer options** and turn on **USB debugging**.")
        StepRow(number: 3, text: "Connect the phone to this Mac with a USB cable.")
        StepRow(number: 4, text: "Tap **Allow** when your phone asks.")
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassPanel()
    } footer: {
      Label { Text("Waiting for a phone on USB…") } icon: { ProgressView().controlSize(.small) }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: Shared pieces

private struct ScreenTitle: View {
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.title3.weight(.semibold))
      Text(subtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct BackButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Back", systemImage: "chevron.left")
        .font(.callout.weight(.medium))
    }
    .buttonStyle(.plain)
    .foregroundStyle(.tint)
    .keyboardShortcut(.cancelAction)
  }
}

private struct StepRow: View {
  let number: Int
  let text: LocalizedStringKey

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(verbatim: "\(number)")
        .font(.caption.weight(.bold))
        .foregroundStyle(.tint)
        .frame(width: 20, height: 20)
        .background(Color.accentColor.opacity(0.18), in: Circle())
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
      Text(text)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct StatusLine: View {
  let phase: PairingModel.Phase
  let idleText: LocalizedStringKey?

  var body: some View {
    Group {
      switch phase {
      case .idle:
        if let idleText {
          Label { Text(idleText) } icon: { ProgressView().controlSize(.small) }
            .foregroundStyle(.secondary)
        }
      case .working(let message):
        Label { Text(message) } icon: { ProgressView().controlSize(.small) }
          .foregroundStyle(.secondary)
      case .succeeded(let message):
        Label(message, systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      case .failed(let message):
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
    }
    .font(.callout)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity)
  }
}

private struct QRCodeImage: View {
  let payload: String

  var body: some View {
    if let image = Self.render(payload) {
      Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
    } else {
      Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.black)
    }
  }

  private static func render(_ payload: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(payload.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage,
          let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  }
}
