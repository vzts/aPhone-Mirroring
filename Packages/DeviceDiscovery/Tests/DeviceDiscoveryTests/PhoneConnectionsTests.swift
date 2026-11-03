import XCTest
import SharedModels
@testable import DeviceDiscovery

final class PhoneConnectionsTests: XCTestCase {
  // A Galaxy S23 seen three ways, plus an unrelated phone.
  let mdns = Device(id: "adb-R3CW607FSQR-JIrYSJ._adb-tls-connect._tcp", transport: .wifi, state: .online)
  let ip = Device(id: "192.168.11.103:41945", transport: .wifi, state: .online)
  let usb = Device(id: "R3CW607FSQR", transport: .usb, state: .online)
  let other = Device(id: "emulator-5554", transport: .usb, state: .online)
  let keys = [
    "adb-R3CW607FSQR-JIrYSJ._adb-tls-connect._tcp": "s23",
    "192.168.11.103:41945": "s23",
    "R3CW607FSQR": "s23",
    "emulator-5554": "emulator",
  ]

  private func collapse(_ devices: [Device], current: [String: String] = [:], preferred: Set<String> = []) -> [String] {
    PhoneConnections.collapse(devices, phoneKey: { self.keys[$0] }, current: current,
                              preferred: { preferred.contains($0) }).devices.map(\.id)
  }

  func test_onePhoneTwoConnections_listedOnce() {
    XCTAssertEqual(collapse([mdns, ip, other]), [mdns.id, other.id])
  }

  func test_keepsTheMirroredConnectionWhenACableIsPluggedIn() {
    // A mirrored serial is trusted; the new cable may be too.
    XCTAssertEqual(collapse([mdns, usb], current: ["s23": mdns.id], preferred: [mdns.id]), [mdns.id])
    XCTAssertEqual(collapse([mdns, usb], current: ["s23": mdns.id], preferred: [mdns.id, usb.id]), [mdns.id])
  }

  func test_untrustedCableYieldsToTrustedWiFi() {
    // Listed over USB (never mirrored that way), then wireless debugging returns.
    XCTAssertEqual(collapse([usb, mdns], current: ["s23": usb.id], preferred: [mdns.id]), [mdns.id])
  }

  func test_newPhonePrefersTrustedThenUSB() {
    XCTAssertEqual(collapse([mdns, usb]), [usb.id])
    XCTAssertEqual(collapse([mdns, usb], preferred: [mdns.id]), [mdns.id])
  }

  func test_fallsBackWhenThePublishedConnectionGoesAway() {
    var gone = mdns; gone.state = .offline
    XCTAssertEqual(collapse([gone, usb], current: ["s23": mdns.id]), [usb.id])
  }

  func test_unknownPhoneIsLeftAlone() {
    XCTAssertEqual(
      PhoneConnections.collapse([mdns, ip], phoneKey: { _ in nil }, current: [:], preferred: { _ in false }).devices.map(\.id),
      [mdns.id, ip.id])
  }
}
