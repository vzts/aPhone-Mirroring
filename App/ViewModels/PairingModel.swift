import Combine
import Foundation
import ADBKit
import DeviceDiscovery
import SharedModels

/// Wireless pairing flow behind the Connect window: QR pairing (auto), pairing
/// code, and manual IP. After a successful pair it waits for adb's mDNS
/// auto-connect, trusts the resulting serial so Mirror opens on its own, and
/// only falls back to an explicit `adb connect` if the phone never shows up.
@MainActor
final class PairingModel: ObservableObject {
  enum Phase: Equatable {
    case idle
    case working(String)
    case succeeded(String)
    case failed(String)

    var isWorking: Bool { if case .working = self { return true } else { return false } }
  }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var qrName = PairingModel.newQRName()
  @Published private(set) var qrPassword = PairingModel.newQRPassword()

  let browser = WirelessBrowser()
  private let wireless: ADBWirelessClient
  private let adb = ADBClient()
  private var browserSink: AnyCancellable?
  private var qrPairingStarted = false

  init(wireless: ADBWirelessClient = ResourceLocator.wirelessClient()) {
    self.wireless = wireless
    browserSink = browser.objectWillChange.sink { [weak self] _ in
      // WirelessBrowser publishes before it mutates; look at the new value next turn.
      DispatchQueue.main.async { self?.browserChanged() }
      self?.objectWillChange.send()
    }
  }

  var qrPayload: String { "WIFI:T:ADB;S:\(qrName);P:\(qrPassword);;" }

  /// Phones currently showing "Pair device with pairing code".
  var codeCandidates: [WirelessEndpoint] {
    browser.pairingCandidates.filter { $0.serviceName != qrName }
  }

  func start() { browser.start() }
  func stop() { browser.stop() }

  func regenerateQR() {
    qrName = Self.newQRName()
    qrPassword = Self.newQRPassword()
    qrPairingStarted = false
    if case .failed = phase { phase = .idle }
  }

  func clearStatus() {
    if !phase.isWorking { phase = .idle }
  }

  // MARK: flows

  func pair(_ endpoint: WirelessEndpoint, code: String) {
    guard !phase.isWorking else { return }
    run(pairHost: endpoint.host) {
      try await self.wireless.pair(host: endpoint.host, port: endpoint.port, code: code)
    }
  }

  func connectManually(host: String, port: Int, code: String) {
    guard !phase.isWorking else { return }
    if code.isEmpty {
      phase = .working(String(localized: "Connecting…"))
      Task {
        do {
          try await wireless.connect(host: host, port: port)
          SessionCoordinator.shared.trustDevice("\(host):\(port)")
          phase = .succeeded(String(localized: "Connected."))
        } catch {
          phase = .failed(Self.describe(error))
        }
      }
    } else {
      run(pairHost: host) {
        try await self.wireless.pair(host: host, port: port, code: code)
      }
    }
  }

  private func browserChanged() {
    guard !qrPairingStarted, !phase.isWorking,
          let match = browser.pairingCandidates.first(where: { $0.serviceName == qrName })
    else { return }
    qrPairingStarted = true
    run(pairHost: match.host) {
      try await self.wireless.pair(host: match.host, port: match.port, code: self.qrPassword)
    }
  }

  private func run(pairHost: String, pair: @escaping () async throws -> Void) {
    phase = .working(String(localized: "Pairing…"))
    Task {
      do {
        try await pair()
        phase = .working(String(localized: "Paired. Connecting…"))
        try await finishPairing(host: pairHost)
        phase = .succeeded(String(localized: "Connected. Starting Mirror…"))
      } catch {
        qrPairingStarted = false
        phase = .failed(Self.describe(error))
      }
    }
  }

  /// adb auto-connects freshly paired phones over mDNS within a second or two.
  /// Trust whatever serial that produces; connect by hand only if it doesn't.
  private func finishPairing(host: String) async throws {
    for _ in 0..<12 {
      if let endpoint = browser.connectableDevices.first(where: { $0.host == host }) {
        let mdnsSerial = "\(endpoint.serviceName)._adb-tls-connect._tcp"
        let ipSerial = "\(endpoint.host):\(endpoint.port)"
        SessionCoordinator.shared.trustDevice(mdnsSerial)
        SessionCoordinator.shared.trustDevice(ipSerial)
        let online = (try? await adb.listDevices())?.filter { $0.state == .online }.map(\.id) ?? []
        if online.contains(mdnsSerial) || online.contains(ipSerial) { return }
        if online.contains(where: { $0.hasPrefix(endpoint.serviceName) }) { return }
      }
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    guard let endpoint = browser.connectableDevices.first(where: { $0.host == host }) else {
      throw ADBWirelessClient.WirelessError.missingMDNS
    }
    try await wireless.connect(host: endpoint.host, port: endpoint.port)
  }

  // MARK: helpers

  private static func newQRName() -> String { "aPhone-\(Int.random(in: 1000...9999))" }
  private static func newQRPassword() -> String { String(format: "%06d", Int.random(in: 0..<1_000_000)) }

  static func describe(_ error: Error) -> String {
    guard let err = error as? ADBWirelessClient.WirelessError else { return error.localizedDescription }
    switch err {
    case .missingMDNS: return String(localized: "No wireless ADB service found on this network.")
    case .pairingTimeout: return String(localized: "Pairing timed out — keep the pair screen open on the device.")
    case .pairingInvalidCode: return String(localized: "Wrong pairing code — try again.")
    case .pairingSwitchFailed: return String(localized: "Device rejected the pairing.")
    case .connectUnverified: return String(localized: "Device is not authorized — accept the prompt on Android.")
    case .addressInvalid(let s): return String(localized: "Invalid address: \(s)")
    case .adbMissing: return String(localized: "Bundled adb is missing — reinstall \(AppInfo.name).")
    case .adb(let s): return s.isEmpty ? String(localized: "adb returned an unknown error.") : s
    }
  }
}

extension WirelessEndpoint {
  /// "adb-R3CW607FSQR-JIrYSJ" → "R3CW607FSQR"; anything else unchanged.
  var deviceSerialHint: String {
    let parts = serviceName.split(separator: "-")
    if parts.count >= 3, parts.first == "adb" { return String(parts[1]) }
    return serviceName
  }
}
