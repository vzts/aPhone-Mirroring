import XCTest
@testable import ScrcpyClient

/// scrcpy 4.0+ wire-format details the client depends on.
final class ProtocolV5Tests: XCTestCase {
  func test_mediaPacketFlags_sitBelowTheSessionBit() {
    XCTAssertEqual(VideoFrame.sessionFlag, 1 << 63)
    XCTAssertEqual(VideoFrame.configFlag, 1 << 62)
    XCTAssertEqual(VideoFrame.keyFrameFlag, 1 << 61)
    XCTAssertEqual(VideoFrame.ptsMask & VideoFrame.keyFrameFlag, 0)
    XCTAssertEqual(AudioFrame.configFlag, VideoFrame.configFlag)
    XCTAssertEqual(AudioFrame.keyFrameFlag, VideoFrame.keyFrameFlag)
    XCTAssertEqual(AudioFrame.ptsMask, VideoFrame.ptsMask)
  }

  func test_scroll_isEncodedOverPlusMinus16() {
    // The server multiplies the decoded [-1, 1] value by 16.
    XCTAssertEqual(ControlMessage.scrollFixedPoint(16), Int16.max)
    XCTAssertEqual(ControlMessage.scrollFixedPoint(-16), -Int16.max)
    XCTAssertEqual(ControlMessage.scrollFixedPoint(1), Int16(Double(Int16.max) / 16))
    XCTAssertEqual(ControlMessage.scrollFixedPoint(100), Int16.max)
  }

  func test_serverVersion_matchesBundledJar() {
    XCTAssertEqual(ScrcpyServerVersion.current, "5.0.1")
  }
}
