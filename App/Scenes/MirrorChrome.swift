import AppKit

// MARK: - Title bar controls

/// The Mirror window's title strip, trailing edge: Android navigation
/// (Back, Home, Recents) in one capsule, then the frequent tools (Screenshot,
/// phone screen on/off) and the More menu in a second one, a small gap apart.
/// Traffic lights keep the leading edge, as in iPhone Mirroring.
///
/// The capsules are opaque and bezel-coloured on purpose. The strip above the
/// phone is a transparent part of the window, so glass there showed the
/// desktop through it and the window shadow traced its translucent edge as a
/// stray outline.
@MainActor
final class MirrorTitlebarControls: NSView {
  private(set) var moreButton: NSButton!
  private var navStack: NSStackView!
  private var backButton: NSButton!
  private var homeButton: NSButton!
  private var recentsButton: NSButton!
  private var screenButton: NSButton!
  private var actions: [Int: () -> Void] = [:]
  private let onMore: (NSView) -> Void

  private enum Tag: Int { case back, home, recents, screenshot, screen, more }

  init(
    onBack: @escaping () -> Void,
    onHome: @escaping () -> Void,
    onRecents: @escaping () -> Void,
    onScreenshot: @escaping () -> Void,
    onTogglePhoneScreen: @escaping () -> Void,
    onMore: @escaping (NSView) -> Void
  ) {
    self.onMore = onMore
    super.init(frame: .zero)
    actions = [
      Tag.back.rawValue: onBack, Tag.home.rawValue: onHome, Tag.recents.rawValue: onRecents,
      Tag.screenshot.rawValue: onScreenshot, Tag.screen.rawValue: onTogglePhoneScreen,
    ]
    appearance = NSAppearance(named: .darkAqua)

    backButton = makeButton(Self.navIcon(.back), String(localized: "Back"), tag: .back)
    homeButton = makeButton(Self.navIcon(.home), String(localized: "Home"), tag: .home)
    recentsButton = makeButton(Self.navIcon(.recents), String(localized: "Recents"), tag: .recents)
    let screenshot = makeButton(Self.symbol("camera"), String(localized: "Take Screenshot"), tag: .screenshot)
    screenButton = makeButton(Self.screenIcon(lit: true), String(localized: "Turn Off Phone Screen"), tag: .screen)
    moreButton = makeButton(Self.symbol("ellipsis"), String(localized: "More"), tag: .more)

    let (navPill, navStack) = Self.makePill([backButton, homeButton, recentsButton])
    self.navStack = navStack
    let (toolPill, _) = Self.makePill([screenshot, screenButton, moreButton])

    let row = NSStackView(views: [navPill, toolPill])
    row.orientation = .horizontal
    row.spacing = 6
    addSubview(row)
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Reflect Settings › Turn off phone screen while mirroring: a filled sun
  /// while the phone screen is lit, an outline sun while it's dark.
  func setPhoneScreenOff(_ off: Bool) {
    screenButton.image = Self.screenIcon(lit: !off)
    let label = off ? String(localized: "Turn On Phone Screen") : String(localized: "Turn Off Phone Screen")
    screenButton.toolTip = label
    screenButton.setAccessibilityLabel(label)
  }

  /// Match the phone's own button order. Samsung lets users swap Back and
  /// Recents (`navigationbar_key_order` 0 = Recents·Home·Back, the One UI
  /// default); stock Android is Back·Home·Recents.
  func setNavigationOrder(backFirst: Bool) {
    let nav: [NSButton] = backFirst ? [backButton, homeButton, recentsButton] : [recentsButton, homeButton, backButton]
    for (index, button) in nav.enumerated() {
      navStack.removeArrangedSubview(button)
      navStack.insertArrangedSubview(button, at: index)
    }
  }

  private static func makePill(_ buttons: [NSButton]) -> (NSView, NSStackView) {
    let stack = NSStackView(views: buttons)
    stack.orientation = .horizontal
    stack.spacing = 0
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
    let pill = NSView()
    pill.wantsLayer = true
    pill.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
    pill.layer?.cornerRadius = 13
    pill.layer?.cornerCurve = .continuous
    pill.layer?.borderWidth = 1
    pill.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
    pill.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
      stack.topAnchor.constraint(equalTo: pill.topAnchor),
      stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
      pill.heightAnchor.constraint(equalToConstant: 26),
    ])
    return (pill, stack)
  }

  private static func screenIcon(lit: Bool) -> NSImage {
    symbol(lit ? "sun.max.fill" : "sun.max")
  }

  private static func symbol(_ name: String) -> NSImage {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)) ?? NSImage()
  }

  private enum NavIcon { case back, home, recents }

  /// One UI's three-button navigation glyphs — thin round-capped strokes:
  /// a chevron, a rounded square, three bars. Drawn rather than taken from SF
  /// Symbols, which have no matching home or recents shape.
  private static func navIcon(_ kind: NavIcon) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
      let path = NSBezierPath()
      path.lineWidth = 1.6
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      switch kind {
      case .back:
        path.move(to: NSPoint(x: 10, y: 3.5))
        path.line(to: NSPoint(x: 5.5, y: 8))
        path.line(to: NSPoint(x: 10, y: 12.5))
      case .home:
        path.appendRoundedRect(NSRect(x: 3.25, y: 3.25, width: 9.5, height: 9.5), xRadius: 3.4, yRadius: 3.4)
      case .recents:
        for x in [4.5, 8.0, 11.5] {
          path.move(to: NSPoint(x: x, y: 4))
          path.line(to: NSPoint(x: x, y: 12))
        }
      }
      NSColor.black.setStroke()
      path.stroke()
      return true
    }
    image.isTemplate = true
    return image
  }

  private func makeButton(_ image: NSImage, _ label: String, tag: Tag) -> NSButton {
    let button = NSButton(image: image, target: self, action: #selector(pressed(_:)))
    button.tag = tag.rawValue
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.imagePosition = .imageOnly
    button.contentTintColor = .labelColor
    button.toolTip = label
    button.setAccessibilityLabel(label)
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 28),
      button.heightAnchor.constraint(equalToConstant: 26),
    ])
    return button
  }

  @objc private func pressed(_ sender: NSButton) {
    if sender.tag == Tag.more.rawValue { onMore(sender) } else { actions[sender.tag]?() }
  }
}

// MARK: - Closure-backed menu item

final class ActionMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(
    _ title: String,
    symbol: String? = nil,
    key: String = "",
    modifiers: NSEvent.ModifierFlags = [.command],
    state: NSControl.StateValue = .off,
    handler: @escaping () -> Void
  ) {
    self.handler = handler
    super.init(title: title, action: #selector(fire), keyEquivalent: key)
    target = self
    keyEquivalentModifierMask = modifiers
    self.state = state
    if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
  }

  required init(coder: NSCoder) { fatalError() }

  @objc private func fire() { handler() }
}

// MARK: - Window frame persistence

/// Where "the phone" sits on screen. The Mirror and Connect windows share the
/// last frame so connecting doesn't make the phone jump; each device also keeps
/// its own frame for when several are mirrored at once.
enum MirrorFramePersistence {
  private static let lastKey = "mirror.lastWindowFrame"
  private static func deviceKey(_ serial: String) -> String { "mirror.windowFrame.\(serial)" }

  static func save(_ frame: NSRect, serial: String?) {
    let dict: [String: CGFloat] = [
      "x": frame.origin.x, "y": frame.origin.y,
      "width": frame.size.width, "height": frame.size.height,
    ]
    if let serial { UserDefaults.standard.set(dict, forKey: deviceKey(serial)) }
    UserDefaults.standard.set(dict, forKey: lastKey)
  }

  static func lastFrame() -> NSRect? { read(lastKey) }
  static func frame(serial: String) -> NSRect? { read(deviceKey(serial)) }

  /// Resize a saved frame to the given content aspect, keeping its centre and
  /// the phone's long edge (so a frame saved in landscape still gives a
  /// full-size portrait window), then keep it on screen.
  @MainActor
  static func fit(_ frame: NSRect, aspect: NSSize, in window: NSWindow) -> NSRect {
    guard aspect.width > 0, aspect.height > 0 else { return frame }
    let content = window.contentRect(forFrameRect: frame)
    let longEdge = max(content.width, content.height)
    var size = aspect.height >= aspect.width
      ? NSSize(width: longEdge * aspect.width / aspect.height, height: longEdge)
      : NSSize(width: longEdge, height: longEdge * aspect.height / aspect.width)
    let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main
    let visible = screen?.visibleFrame ?? frame
    let scale = min(1, (visible.height - 24) / size.height, (visible.width * 0.85) / size.width)
    size = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    var rect = NSRect(x: (content.midX - size.width / 2).rounded(), y: (content.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - rect.width)
    rect.origin.y = min(max(rect.minY, visible.minY), visible.maxY - rect.height)
    return window.frameRect(forContentRect: rect)
  }

  private static func read(_ key: String) -> NSRect? {
    guard let d = UserDefaults.standard.dictionary(forKey: key) as? [String: CGFloat],
          let x = d["x"], let y = d["y"], let w = d["width"], let h = d["height"],
          w > 0, h > 0 else { return nil }
    return NSRect(x: x, y: y, width: w, height: h)
  }
}

extension MirrorWindowController {
  /// The Mirror window the Device menu acts on.
  static var key: MirrorWindowController? {
    (NSApp.keyWindow?.windowController as? MirrorWindowController)
      ?? (NSApp.mainWindow?.windowController as? MirrorWindowController)
  }
}

// MARK: - Default size

/// First-run size for the phone-shaped windows: about what iPhone Mirroring
/// uses — tall enough to read the phone comfortably, never taller than 920 pt
/// on big displays, and never wider than most of the screen in landscape.
enum PhoneWindowSizing {
  @MainActor
  static func defaultFrame(aspect: NSSize, in window: NSWindow, screen: NSScreen?) -> NSRect {
    let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    guard aspect.width > 0, aspect.height > 0 else { return window.frame }
    var height = min(max(visible.height * 0.82, 560), 920, visible.height - 24)
    var width = height * aspect.width / aspect.height
    let maxWidth = visible.width * 0.85
    if width > maxWidth {
      width = maxWidth
      height = width * aspect.height / aspect.width
    }
    var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width.rounded(), height: height.rounded()))
    frame.origin = NSPoint(x: (visible.midX - frame.width / 2).rounded(), y: (visible.midY - frame.height / 2).rounded())
    return frame
  }
}

// MARK: - Screenshots

/// Screenshots land on the Desktop, named like macOS's own
/// ("Screenshot s23 2026-11-03 18.40.12.png"), and never overwrite.
enum ScreenshotLocation {
  static func newFileURL(source: String) -> URL {
    let fm = FileManager.default
    let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
      ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let safeSource = source.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    let base = "\(String(localized: "Screenshot")) \(safeSource) \(formatter.string(from: Date()))"
    var url = desktop.appendingPathComponent(base).appendingPathExtension("png")
    var n = 2
    while fm.fileExists(atPath: url.path) {
      url = desktop.appendingPathComponent("\(base) \(n)").appendingPathExtension("png")
      n += 1
    }
    return url
  }
}
