import Foundation
import Network
import SharedModels

/// One frame as delivered by scrcpy-server over the video socket.
///
/// Every packet starts with a 12-byte big-endian header whose top bit tells
/// session packets from media packets (scrcpy 4.0+):
///   session: bit 63 = 1, bit 32 = client-resized, bytes 4-7 width, 8-11 height
///   media:   bit 63 = 0, bit 62 = CONFIG, bit 61 = KEY_FRAME,
///            bits 60-0 = PTS (µs), bytes 8-11 = payload size (u32)
public struct VideoFrame: Sendable {
  public static let sessionFlag: UInt64 = 1 << 63
  public static let configFlag: UInt64 = 1 << 62
  public static let keyFrameFlag: UInt64 = 1 << 61
  public static let ptsMask: UInt64 = (1 << 61) - 1

  public let pts: UInt64          // microseconds; .max for config packets
  public let isConfig: Bool
  public let isKeyframe: Bool
  public let payload: Data        // Annex-B NAL units

  public init(pts: UInt64, isConfig: Bool, isKeyframe: Bool, payload: Data) {
    self.pts = pts
    self.isConfig = isConfig
    self.isKeyframe = isKeyframe
    self.payload = payload
  }
}

/// Reads the scrcpy 5.x video framing protocol off an `NWConnection`.
/// `nextFrame()` returns the next media packet. Session packets (one per
/// capture session, e.g. after a rotation) are skipped: the renderer picks up
/// size changes from the decoded frames themselves.
public actor VideoStream {
  private let conn: NWConnection

  public init(connection: NWConnection) {
    self.conn = connection
  }

  public func nextFrame() async throws -> VideoFrame {
    var header = try await readExact(12)
    var pts64 = header.subdata(in: 0..<8).withUnsafeBytes { $0.load(as: UInt64.self) }.bigEndian
    while pts64 & VideoFrame.sessionFlag != 0 {
      header = try await readExact(12)
      pts64 = header.subdata(in: 0..<8).withUnsafeBytes { $0.load(as: UInt64.self) }.bigEndian
    }
    let size = header.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian

    let isConfig = (pts64 & VideoFrame.configFlag) != 0
    let isKey = (pts64 & VideoFrame.keyFrameFlag) != 0
    let pts = pts64 & VideoFrame.ptsMask

    let payload = try await readExact(Int(size))
    return VideoFrame(pts: pts, isConfig: isConfig, isKeyframe: isKey, payload: payload)
  }

  public func close() {
    conn.cancel()
  }

  private func readExact(_ count: Int) async throws -> Data {
    var acc = Data()
    acc.reserveCapacity(count)
    while acc.count < count {
      let want = count - acc.count
      let chunk: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
        conn.receive(minimumIncompleteLength: 1, maximumLength: want) { data, _, isComplete, error in
          if let error { cont.resume(throwing: error); return }
          if let data, !data.isEmpty {
            cont.resume(returning: data); return
          }
          if isComplete {
            cont.resume(throwing: DroidMirroringError.scrcpyProtocol("video socket closed"))
            return
          }
          cont.resume(returning: Data())
        }
      }
      acc.append(chunk)
    }
    return acc
  }
}
