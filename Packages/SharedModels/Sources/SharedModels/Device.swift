import Foundation

public struct Device: Identifiable, Hashable, Sendable, Codable {
  public enum Transport: String, Sendable, Codable { case usb, wifi, unknown }
  public enum State: String, Sendable, Codable { case online, offline, unauthorized, recovery }

  public let id: String              // adb serial
  public var model: String
  /// The name the user gave the phone (Settings › About phone › Device name).
  public var name: String
  public var manufacturer: String
  public var androidSDK: Int
  public var transport: Transport
  public var state: State

  public init(
    id: String,
    model: String = "",
    name: String = "",
    manufacturer: String = "",
    androidSDK: Int = 0,
    transport: Transport = .unknown,
    state: State = .offline
  ) {
    self.id = id
    self.model = model
    self.name = name
    self.manufacturer = manufacturer
    self.androidSDK = androidSDK
    self.transport = transport
    self.state = state
  }
}

public extension Device {
  var isSamsung: Bool { manufacturer.lowercased() == "samsung" }
  var supportsFreeform: Bool { androidSDK >= 34 }
  /// adb reports models with underscores ("SM_S911N").
  var modelName: String { model.replacingOccurrences(of: "_", with: "-") }
  /// Best label for UI: the phone's own name, else its model, else the serial.
  var displayName: String {
    if !name.isEmpty { return name }
    if !model.isEmpty { return modelName }
    return id
  }
}
