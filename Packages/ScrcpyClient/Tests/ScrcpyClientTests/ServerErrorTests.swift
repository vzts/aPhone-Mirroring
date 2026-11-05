import XCTest
@testable import ScrcpyClient

/// What a failed launch reports from the server's console (scrcpy's `Ln`
/// prints `[server] ERROR: <message>`, then the stack trace for `Ln.e(_, t)`).
final class ServerErrorTests: XCTestCase {
  func test_firstErrorLine_isTheReason() {
    let lines = [
      "[server] INFO: Device: [samsung] samsung SM-X115 (Android 16)",
      "[server] ERROR: Could not create default video encoder for h264",
      "[server] ERROR: Video encoding error",
    ]
    XCTAssertEqual(ScrcpyServerLauncher.serverError(in: lines), "Could not create default video encoder for h264")
  }

  func test_exceptionUnderTheLine_isKept() {
    let lines = [
      "[server] ERROR: Capture/encoding error: x",
      "java.lang.IllegalStateException: Could not create display",
      "\tat com.genymobile.scrcpy.video.ScreenCapture.start(ScreenCapture.java:1)",
    ]
    XCTAssertEqual(
      ScrcpyServerLauncher.serverError(in: lines),
      "Capture/encoding error: x (java.lang.IllegalStateException: Could not create display)")
  }

  func test_nullMessage_fallsBackToTheException() {
    let lines = ["[server] ERROR: null", "java.lang.NullPointerException: Attempt to invoke"]
    XCTAssertEqual(ScrcpyServerLauncher.serverError(in: lines), "java.lang.NullPointerException: Attempt to invoke")
  }

  func test_noErrorLine_isNoReason() {
    XCTAssertNil(ScrcpyServerLauncher.serverError(in: ["[server] INFO: ok", "[server] WARN: slow"]))
  }
}
