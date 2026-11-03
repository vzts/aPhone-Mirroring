import SharedModels

/// adb lists a phone once per connection: a USB cable, wireless debugging
/// found over mDNS, and an `adb connect` by IP are three serials for one
/// phone. Everything above the monitor (Connect window, menu bar, auto-mirror)
/// must see one phone, or it gets mirrored once per connection.
enum PhoneConnections {
  /// Keeps one online serial per phone and drops that phone's other entries.
  /// - phoneKey: the phone's identity (android_id) for an adb serial; nil when unknown.
  /// - current: phone → serial published last time; among equally preferred
  ///   connections it stays, so a cable plugged in mid-mirror doesn't move the
  ///   mirror (a mirrored serial is always trusted).
  /// - preferred: serials worth keeping first (the app's trusted phones), so
  ///   auto-mirror still finds a serial it knows.
  static func collapse(
    _ devices: [Device],
    phoneKey: (String) -> String?,
    current: [String: String],
    preferred: (String) -> Bool
  ) -> (devices: [Device], chosen: [String: String]) {
    var online: [String: [Device]] = [:]
    for device in devices where device.state == .online {
      if let key = phoneKey(device.id) { online[key, default: []].append(device) }
    }
    var chosen: [String: String] = [:]
    for (key, members) in online {
      let kept = current[key]
      chosen[key] = members.min { rank($0, kept, preferred) < rank($1, kept, preferred) }!.id
    }
    let result = devices.filter { device in
      guard let key = phoneKey(device.id), let pick = chosen[key] else { return true }
      return device.id == pick
    }
    return (result, chosen)
  }

  private static func rank(_ device: Device, _ kept: String?, _ preferred: (String) -> Bool) -> (Int, Int, Int) {
    let route: Int
    if device.transport == .usb { route = 0 }
    else if device.id.hasSuffix("._adb-tls-connect._tcp") { route = 1 }  // survives IP changes
    else { route = 2 }
    return (preferred(device.id) ? 0 : 1, device.id == kept ? 0 : 1, route)
  }
}
