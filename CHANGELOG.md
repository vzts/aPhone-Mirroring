# Changelog

All notable changes to aPhone Mirroring (formerly DroidMirroring) will be documented in this file.

## [v2.2.0] - 2026-11-06

### Added
- Update notices. On its second launch the app asks whether to check
  GitHub for a new version once a day; when one is out, it says what
  changed since your version and opens the download. Check for Updates…
  checks any time, and Settings › Advanced › Updates turns the daily
  check off. A scheduled check never pulls the app in front of what
  you're doing: it waits until you're in the app, and the menu bar menu
  offers the update meanwhile.

## [v2.1.1] - 2026-11-06

### Fixed
- Phones that can only encode H.265 in software (and the Android
  emulator) mirrored at a fraction of their screen, small and blurry.
  They now switch to H.264 and mirror at full size.
- After a phone reconnected, the first notification from an app without
  a launcher icon could arrive a few seconds late.

## [v2.1.0] - 2026-11-06

### Added
- Phone notifications in Notification Center. Turn on Settings › General ›
  Show phone notifications on this Mac: a connected phone's new
  notifications appear with the sender, the app and the message; updates
  replace them, dismissing one on the phone removes it from the Mac, and
  clicking one opens its app on the phone. Silent and ongoing
  notifications, and what Do Not Disturb holds back, stay on the phone.
  Nothing is installed on the phone, and notifications stay on the Mac.

## [v2.0.6] - 2026-11-06

### Fixed
- A phone that only mirrors with Android's software encoder now has
  sound from the first session, not only after a relaunch.

### Changed
- The USB screen also suggests restarting the phone and turning USB
  debugging off and on when the phone never asks to allow the Mac.

## [v2.0.5] - 2026-11-06

### Fixed
- Dragging to scroll no longer throws the list to its end. Lists now
  coast as far as the flick carries them, and stay put when you stop
  before letting go, as with a finger.
- When mirroring can't start, the alert now includes the phone's own
  reason instead of only "short read on video socket".
- Phones whose video encoder won't start fall back to Android's software
  encoder, and a display the phone doesn't have falls back to its main
  display.

### Changed
- The Connect window explains how to turn on Developer options
  (including where Build number is on Samsung), Wireless debugging, and
  USB debugging.
- The USB screen says what to try when the phone never asks to allow
  the Mac, prompts you to tap Allow while the phone is waiting, and
  carries on once you do.

## [v2.0.4] - 2026-11-03

### Fixed
- Cmd-V pastes into the phone. The Mac's editing shortcuts (Cmd-X, Cmd-C,
  Cmd-V, Cmd-A, Cmd-Z, Shift-Cmd-Z) and the Edit menu now work in the mirror
  window; what you copy on the phone comes back to the Mac when clipboard
  sharing is on.
- Command shortcuts the app doesn't use no longer reach the phone, where they
  could set off Android system shortcuts such as opening Settings.

## [v2.0.3] - 2026-11-03

### Fixed
- A phone connected more than one way (USB and Wi-Fi, or by IP address and
  over wireless debugging) is listed and mirrored once instead of once per
  connection.
- Dragging a window in Desktop Mode no longer throws it past where you let go.
- After pairing, the Connect window says what actually happens: a phone that's
  already mirrored is brought forward, a closed mirror opens again, and it no
  longer promises a mirror when "Start mirroring when a phone connects" is off.
- Connecting by IP address to a port that's no longer open now says the phone
  can't be reached, instead of asking you to keep a pairing screen open.

## [v2.0.2] - 2026-11-03

### Fixed
- The phone's on-screen keyboard now appears while mirroring, so you can
  type on the phone itself. The phone's setting is put back when the mirror
  ends.
- Closing a mirror or Desktop Mode window with the close button now ends the
  session on the phone: the phone sleeps normally again and Desktop Mode's
  virtual display goes away.
- A Wi-Fi blip while connecting no longer leaves a "Couldn't start mirroring"
  alert that blocks auto-mirroring; the mirror reopens when the phone is back.
- The no-audio and H.264 fallbacks now also apply when the mirror restarts
  after a settings or display change.
- The mirror no longer restarts right after it opens because it mistook its
  own virtual display for a new phone screen.
- Desktop Mode and Files windows show the phone's name instead of its model.

## [v2.0.1] - 2026-11-03

### Changed
- Record and Rotate are now title-bar buttons next to Screenshot.
- Back / Home / Recents are hidden by default; show them from More or the
  View menu.
- New shortcuts: Cmd-R rotates the screen, Cmd-D turns the phone screen on
  or off (Refresh Active Display moved to Opt-Cmd-R). Tooltips show each
  button's shortcut.

### Fixed
- Changing the language in Settings now offers a restart and applies.

## [v2.0.0] - 2026-11-03

### Changed
- Renamed to aPhone Mirroring, with a new icon.
- Redesigned interface: one phone-shaped window from connecting to mirroring,
  QR pairing by default, One UI-style navigation buttons, native menus, and
  System Settings-style preferences that apply right away.
- scrcpy-server 5.0.1 (Android 16 and Samsung fixes).
- Default bitrate 8 Mbps; falls back to H.264 when HEVC won't start.

### Added
- 11 languages, following the system language or chosen in Settings.
- Phone screen on/off and screenshot buttons in the title bar; screenshots
  go to the Desktop.
- The phone stays awake while mirroring, so Wi-Fi mirroring doesn't drop.

### Fixed
- Mirror windows keep their size and place across reconnects.
- Pairing in the app now leads straight into mirroring.

## [v1.4.2] - 2026-06-30

### Fixed
- **ZTE F50 投屏修复**：v1.4.1 的音频降级只覆盖了 `audioUnavailable`（socket 超时），但实际设备上 scrcpy-server 会直接崩溃产生 `scrcpyProtocol` 错误。v1.4.2 扩大了降级范围：`audioUnavailable` 和 `scrcpyProtocol` 都会自动降级为无音频重试

## [v1.4.1] - 2026-06-29

### Fixed
- **无音频设备投屏失败修复**（#8）：当设备没有音频 HAL（如 ZTE F50）时，音频 socket 10 秒超时会导致整个投屏崩溃
  - 新增 `audioUnavailable` 错误类型，专门标识音频连接失败
  - 投屏启动失败时自动降级：`audio=true` 超时 → 清理旧进程 → `audio=false` 重试
  - 修复 `MirrorSession` launcher 引用时机，防止重试时旧 server 进程泄漏

## [v1.4.0] - 2026-06-29

### Changed
- **悬浮工具栏简化**：移除独立的文件/桌面按钮，只保留 `⋯` 按钮
- `⋯` 按钮悬停 250ms 自动弹出 More 面板（含文件、桌面、返回、主页、截图等全部操作）
- More 面板改为 4 列网格布局，更紧凑，宽度 340pt

## [v1.2.0] - 2026-06-29

### Added
- **中文本地化**：全部 UI 文本支持简体中文，系统语言为中文时自动显示
- **… 菜单悬停弹出**：菜单栏和镜像窗口中的 `…` 按钮支持鼠标悬停自动弹出
- **⌘. 快捷键**：在镜像窗口中按 `⌘.` 快速打开/关闭 More 操作面板
- 英文本地化（en）备用

### Changed
- 菜单栏 `…` 按钮由 Menu 改为 Popover，悬停 300ms 弹出
- 镜像窗口悬浮栏 `…` 按钮悬停 250ms 自动弹出 More 面板
- More 面板按钮文字支持本地化
- 设备数量显示正确处理单复数

## [v0.2.5] - 2026-06-24

### Added
- CHANGELOG.md for tracking release changes
- Automated release notes extraction from CHANGELOG

## [v0.2.4] - 2026-06-24

### Fixed
- Screen wake now uses `setScreenPowerMode(2)` instead of KEYCODE_POWER for proper screen control
- Device screen is truly off when mirroring starts (no rendering, saves battery)

### Added
- Max FPS support up to 120fps for high refresh rate devices (90Hz/120Hz)
- Updated settings description to mention high refresh rate support

## [v0.2.3] - 2026-06-24

### Fixed
- WiFi pairing fails on networks with IPv6 enabled
- mDNS discovery now filters out IPv6 addresses (adb pair/connect only supports IPv4)

## [v0.2.2] - 2026-06-24

### Fixed
- App version in "About" now matches GitHub Release version
- Settings window not opening from menu bar
- Added Official Website and GitHub Repository links to About menu

## [v0.2.1] - 2026-06-24

### Added
- About menu with version display
- Check for Updates link to GitHub Releases
- Official Website and GitHub Repository links
- Versioned DMG filename (e.g., `DroidMirroring-v0.2.1-universal.dmg`)

## [v0.2.0] - 2026-06-24

### Added
- Unified Logging (os.Logger) for all debug output
- Users can view logs via Console.app: `log show --predicate 'subsystem=="com.droidmirroring.app"'`
- Auto-retry with displayId=0 when launch fails (handles fold/rotation display cache issues)
- Improved error messages with device info and troubleshooting tips

## [v0.1.0] - 2026-06-23

### Initial Release
- Real-time screen mirroring via scrcpy (H.265/VideoToolbox)
- Desktop Mode (Samsung DeX, Android 14+ freeform)
- File Manager with image thumbnails
- USB and Wi-Fi (Android 11+) connection
- Screen recording
- Universal Binary (Apple Silicon + Intel)
- Phone-bezel window design with auto-hiding chrome
- Two-way clipboard sync
- Settings for codec, bitrate, FPS, screen off
