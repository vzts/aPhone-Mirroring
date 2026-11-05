<p align="center">
  <img src="App/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="aPhone Mirroring icon">
</p>

<h1 align="center">aPhone Mirroring</h1>

<p align="center">Use your Android phone from your Mac, the way iPhone Mirroring does.</p>

- Mirror and control the phone in a window, with sound and a shared clipboard
- Connect over Wi-Fi (pair once with a QR code) or USB
- Screenshots, screen recording, file transfer, and a desktop mode on Android 14+
- Available in English, 한국어, 日本語, 简体中文, 繁體中文, Español, Français, Deutsch, Português (Brasil), Русский, and Italiano

## Install

1. Download the DMG from [Releases](https://github.com/vzts/aPhone-Mirroring/releases/latest) and drag **aPhone Mirroring** to Applications.
2. The app isn't notarized. On first launch, open **System Settings › Privacy & Security** and click **Open Anyway**.

Requires macOS 15 or later. Wireless needs Android 11 or later.

## Connect

Developer options appear after tapping **Build number** seven times in **Settings › About phone** (on Samsung, **About phone › Software information**).

- **Wi-Fi:** on the phone, open **Settings › Developer options**, turn on **Wireless debugging**, tap **Pair device with QR code**, and scan the code in the app. The phone and the Mac need to be on the same Wi-Fi.
- **USB:** turn on **USB debugging** in Developer options, plug the phone in, and tap **Allow**. If the phone never asks, use a data cable rather than a charge-only one, turn off **Auto Blocker** on Samsung (**Settings › Security and privacy**), or tap **Revoke USB debugging authorizations** in Developer options and plug in again.

If mirroring won't start, the alert includes the phone's own reason; please add it to a bug report.

## Build

```sh
brew install xcodegen
./scripts/bootstrap.sh   # fetches scrcpy-server and adb
xcodegen generate
open aPhoneMirroring.xcodeproj
```

Building needs Xcode 26 or later (the macOS 26 SDK); the app runs on macOS 15 or later.

## Credits

A fork of [droidMirroring-mac](https://github.com/matyle/droidMirroring-mac). Mirroring is powered by [scrcpy](https://github.com/Genymobile/scrcpy) and [adb](https://developer.android.com/tools/adb). Licensed under [Apache 2.0](LICENSE).
