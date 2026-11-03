# Xcode setup

`.xcodeproj` is **not** checked in — it's regenerated from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen) so that diffs stay readable.

## 一次性

```sh
brew install xcodegen
```

## 每次拉新代码

```sh
./scripts/bootstrap.sh   # 拉 scrcpy-server.jar / adb
xcodegen generate        # 重新生成 aPhoneMirroring.xcodeproj
open aPhoneMirroring.xcodeproj
```

## targets

| Target | Bundle ID | Type |
|---|---|---|
| `aPhoneMirroring` | `io.github.vzts.aphonemirroring` | App (SwiftUI) |
| `ScreenMirroringHelper` | `io.github.vzts.aphonemirroring.ScreenMirroring` | LSUIElement App |
| `FusionModeHelper` | `io.github.vzts.aphonemirroring.FusionMode` | LSUIElement App |
| `ContinueOnHelper` | `io.github.vzts.aphonemirroring.ContinueOn` | LSUIElement App |
| `FileProviderExt` | `io.github.vzts.aphonemirroring.FileProvider` | NSExtension (fileprovider-nonui) |
| `ThumbnailExt` | `io.github.vzts.aphonemirroring.Thumbnail` | NSExtension (quicklook.thumbnail) |

## 签名

DEBUG 用 Personal Team 就行；Release 需在 `project.yml` 把 `DEVELOPMENT_TEAM`
填上 Apple Developer Team ID。FileProvider extension 必须 hardened runtime + sandbox。

## App Group

所有 target 共用 `group.io.github.vzts.aphonemirroring.shared` —— App / Helpers / Extensions
通过 `AppGroup.containerURL`（在 `SharedModels`）读写设备列表 + token。

## DMG 打包

M5 阶段加 `scripts/build-dmg.sh`，调用 `create-dmg` + `notarytool submit`。
MAS 版另起 `project-mas.yml`，砍 FusionModeHelper 与 USB entitlement。
