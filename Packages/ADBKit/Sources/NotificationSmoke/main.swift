import ADBKit
import Foundation

// Prints what PhoneNotificationWatcher reports for one phone, to check the
// notification bridge against a real phone or an emulator:
//   swift run notification-smoke <serial>
setvbuf(stdout, nil, _IOLBF, 0)
guard let serial = CommandLine.arguments.dropFirst().first else {
  print("usage: notification-smoke <serial>")
  exit(2)
}
let watcher = PhoneNotificationWatcher(adb: ADBClient(), serial: serial) { change in
  switch change {
  case .posted(let n, let isUpdate):
    print("\(isUpdate ? "updated" : "posted") \(n.packageName) | \(n.title) | \(n.text.replacingOccurrences(of: "\n", with: "⏎"))")
  case .removed(let key):
    print("removed \(key)")
  }
}
print("watching \(serial)")
await watcher.run(checkEvery: .seconds(20))
