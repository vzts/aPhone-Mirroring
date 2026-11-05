import XCTest
@testable import ADBKit

/// Fixtures follow `NotificationRecord.dump` as `cmd notification get` prints
/// it (prefix "", fields at 2 spaces, the notification block at 4, extras at 8).
final class PhoneNotificationTests: XCTestCase {
  private func record(
    key: String = "0|com.kakao.talk|7|null|10234",
    pkg: String = "com.kakao.talk",
    importance: Int = 4,
    flags: String = "AUTO_CANCEL",
    extras: String = """
            android.title=String (Mina)
            android.text=String (See you at 7?)
    """,
    intercept: Bool = false
  ) -> String {
    """
    NotificationRecord(0x0abc1234: pkg=\(pkg) user=UserHandle{0} id=7 tag=null importance=\(importance) key=\(key): Notification(channel=chat shortcut=null contentView=null vibrate=null sound=null defaults=0x0 flags=0x10 color=0xff000000 vis=PRIVATE))
      uid=10234 userId=0
      opPkg=\(pkg)
      icon=Icon(typ=RESOURCE pkg=\(pkg) id=0x7f080123)
      flags=\(flags)
      originalFlags=\(flags)
      pri=0
      key=\(key)
      seen=false
      groupKey=0|\(pkg)|g:chat
      notification=
        fullscreenIntent=null
        contentIntent=PendingIntent{1234: PendingIntentRecord{5678 \(pkg) startActivity}}
        number=0
        when=1762380000000/1762380000000
        tickerText=null
        vis=0
        extras={
    \(extras)
        }
      publicNotification=
        fullscreenIntent=null
        extras={
            android.title=String (KakaoTalk)
            android.text=String (New message)
        }
      stats=SingleNotificationStats{posttimeElapsedMs=1}
      mImportance=HIGH
      mIntercept=\(intercept)
      mHidden==false
      mUpdateTimeMs=1762380000123
    """
  }

  func test_record_android16_namedFlags() throws {
    let n = try XCTUnwrap(PhoneNotificationParser.parseRecord(record()))
    XCTAssertEqual(n.key, "0|com.kakao.talk|7|null|10234")
    XCTAssertEqual(n.packageName, "com.kakao.talk")
    XCTAssertEqual(n.importance, 4)
    XCTAssertEqual(n.flags, ["AUTO_CANCEL"])
    XCTAssertEqual(n.title, "Mina")          // not the publicNotification's "KakaoTalk"
    XCTAssertEqual(n.text, "See you at 7?")
    XCTAssertTrue(n.isAlerting)
  }

  func test_record_android11_hexFlags() throws {
    let n = try XCTUnwrap(PhoneNotificationParser.parseRecord(record(flags: "0x62")))
    XCTAssertEqual(n.flags, ["ONGOING_EVENT", "NO_CLEAR", "FOREGROUND_SERVICE"])
    XCTAssertFalse(n.isAlerting)
  }

  func test_multilineTextAndSpannedValues() throws {
    let extras = """
            android.title=SpannableString (Team :))
            android.text=SpannableString (line one
    line two)
            android.template=String (android.app.Notification$MessagingStyle)
            android.messages=Parcelable[] (1)
            android.largeIcon=null
    """
    let n = try XCTUnwrap(PhoneNotificationParser.parseRecord(record(extras: extras)))
    XCTAssertEqual(n.title, "Team :)")
    XCTAssertEqual(n.text, "line one\nline two")
  }

  func test_bigTextStandsInForMissingText() throws {
    let extras = """
            android.title=String (Mail)
            android.bigText=String (Long body)
    """
    XCTAssertEqual(PhoneNotificationParser.parseRecord(record(extras: extras))?.text, "Long body")
  }

  func test_quietNotificationsAreNotAlerting() throws {
    let cases: [(String, Int, Bool)] = [
      ("GROUP_SUMMARY|AUTO_CANCEL", 4, false),   // summary of a group
      ("LOCAL_ONLY", 4, false),                  // app says: don't bridge
      ("AUTO_CANCEL", 2, false),                 // low importance: silent
      ("AUTO_CANCEL", 4, true),                  // held back by Do Not Disturb
    ]
    for (flags, importance, intercept) in cases {
      let n = try XCTUnwrap(PhoneNotificationParser.parseRecord(
        record(importance: importance, flags: flags, intercept: intercept)))
      XCTAssertFalse(n.isAlerting, "\(flags) importance=\(importance) intercept=\(intercept)")
    }
    let empty = """
            android.title=null
    """
    XCTAssertEqual(PhoneNotificationParser.parseRecord(record(extras: empty))?.isAlerting, false)
  }

  func test_records_splitOnMarker() {
    let marker = PhoneNotificationParser.recordMarker
    let text = marker + "\n" + record()
      + "\n" + marker + "\n" + record(key: "0|com.whatsapp|2|null|10300", pkg: "com.whatsapp")
      + "\n" + marker + "\nerror: no active notification matching key: x\n"
    XCTAssertNil(PhoneNotificationParser.parseRecords(text), "no end marker: cut short")
    let records = PhoneNotificationParser.parseRecords(text + PhoneNotificationParser.endMarker + "\n")
    XCTAssertEqual(records?.map(\.packageName), ["com.kakao.talk", "com.whatsapp"])
  }

  func test_signatures() {
    let text = "0|com.kakao.talk|7|null|10234\t      mUpdateTimeMs=1762380000123\n"
      + "0|com.whatsapp|2|chat one|10300\t\n"
      + "\t\n"
      + PhoneNotificationParser.endMarker + "\n"
    XCTAssertEqual(PhoneNotificationParser.parseSignatures(text), [
      "0|com.kakao.talk|7|null|10234": "1762380000123",
      "0|com.whatsapp|2|chat one|10300": "",
    ])
    XCTAssertEqual(PhoneNotificationParser.parseSignatures(PhoneNotificationParser.endMarker), [:])
  }

  /// A list cut short, or an error instead of a list, must not read as
  /// "every notification was removed".
  func test_signatures_rejectTruncatedOrErrorOutput() {
    XCTAssertNil(PhoneNotificationParser.parseSignatures("0|com.kakao.talk|7|null|10234\t  mUpdateTimeMs=1\n"))
    XCTAssertNil(PhoneNotificationParser.parseSignatures(
      "error: permission denied: callingUid=2000\n" + PhoneNotificationParser.endMarker))
  }

  func test_packageNameOfKey_tagMayContainBars() {
    XCTAssertEqual(PhoneNotificationParser.packageName(ofKey: "0|com.kakao.talk|7|null|10234"), "com.kakao.talk")
    XCTAssertEqual(PhoneNotificationParser.packageName(
      ofKey: "0|android|1|0|android|g:Aggregate_SilentSection|1000|0|android|g:Aggregate_SilentSection"), "android")
    XCTAssertEqual(PhoneNotificationParser.packageName(ofKey: "-1|android|55|null|1000"), "android")
  }

  /// `cmd notification get` on the Android 16 emulator (API 36), for a
  /// notification posted with `cmd notification post -t Mina aphone-test1 'See you at 7?'`.
  func test_record_realAndroid16Output() throws {
    let dump = """
    NotificationRecord(0x0ac1dc2e: pkg=com.android.shell user=UserHandle{0} id=2020 tag=aphone-test1 importance=3 key=0|com.android.shell|2020|aphone-test1|2000: Notification(channel=shell_cmd shortcut=null contentView=null vibrate=null sound=null defaults=0 flags=0 color=0x00000000 vis=PRIVATE))
      uid=2000 userId=0
      opPkg=com.android.shell
      icon=Icon(typ=RESOURCE pkg=android id=0x01080077)
      flags=0
      originalFlags=0
      pri=0
      key=0|com.android.shell|2020|aphone-test1|2000
      seen=false
      groupKey=0|com.android.shell|2020|aphone-test1|2000
      notification=
        fullscreenIntent=null
        contentIntent=null
        deleteIntent=null
        number=0
        groupAlertBehavior=0
        when=1793895167344/1793895167344
        tickerText=null
        vis=0
        contentView=null
        bigContentView=null
        headsUpContentView=null
        color=0x00000000
        timeout=PT72H
        extras={
            android.title=String (Mina)
            android.reduced.images=Boolean (true)
            android.text=String (See you at 7?)
            android.appInfo=ApplicationInfo (ApplicationInfo{f34f3cf com.android.shell})
            android.showWhen=Boolean (true)
        }
      publicNotification=
        None
      mImportance=DEFAULT
      mIntercept=false
      mHidden==false
      mUpdateTimeMs=1793895167347
    """
    let n = try XCTUnwrap(PhoneNotificationParser.parseRecord(dump))
    XCTAssertEqual(n.key, "0|com.android.shell|2020|aphone-test1|2000")
    XCTAssertEqual(n.packageName, "com.android.shell")
    XCTAssertEqual(n.importance, 3)
    XCTAssertEqual(n.flags, [])
    XCTAssertEqual(n.title, "Mina")
    XCTAssertEqual(n.text, "See you at 7?")
    XCTAssertTrue(n.isAlerting)
  }

  func test_recordsCommand_quotesKeys() {
    let cmd = PhoneNotificationParser.recordsCommand(keys: ["0|a|1|it's|10"])
    XCTAssertTrue(cmd.contains(#"'0|a|1|it'\''s|10'"#))
  }

  func test_appList() {
    let text = """
    [server] INFO: Device: [samsung] samsung SM-X115 (Android 16)
    [server] INFO: List of apps:
     * Settings                       com.android.settings
     - 카카오톡                            com.kakao.talk
     - A Very Long Application Name That Wraps
                                    com.example.longname
     - LINE                           jp.naver.line.android
    """
    XCTAssertEqual(PhoneNotificationParser.parseAppList(text), [
      "com.android.settings": "Settings",
      "com.kakao.talk": "카카오톡",
      "com.example.longname": "A Very Long Application Name That Wraps",
      "jp.naver.line.android": "LINE",
    ])
  }
}
