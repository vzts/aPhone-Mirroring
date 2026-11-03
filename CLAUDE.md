# CLAUDE.md

## Build

The Xcode project is generated from `project.yml`; don't edit or commit
`aPhoneMirroring.xcodeproj`. Building needs Xcode 26 or later (the macOS 26
SDK); the app runs on macOS 15 or later.

```bash
./scripts/bootstrap.sh   # once: scrcpy-server.jar + adb into App/Resources
xcodegen generate
xcodebuild -project aPhoneMirroring.xcodeproj -scheme aPhoneMirroring \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO
codesign --force --deep --sign - "build/dd/Build/Products/Debug/aPhone Mirroring.app"
```

Package tests: `cd Packages/<Name> && swift test`.

## Release

Releases are built locally and published with `gh`; there is no CI workflow.

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`,
   add a `## [vX.Y.Z]` entry to `CHANGELOG.md`, commit `chore: release X.Y.Z`,
   and push `main`.
2. Build a universal, ad-hoc signed app:
   ```bash
   rm -rf build && xcodegen generate
   xcodebuild -project aPhoneMirroring.xcodeproj -scheme aPhoneMirroring \
     -configuration Release -destination 'generic/platform=macOS' \
     -derivedDataPath build/rel build CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO
   APP="build/rel/Build/Products/Release/aPhone Mirroring.app"
   codesign --force --deep --sign - "$APP" && codesign --verify --deep --strict "$APP"
   ```
   `lipo -archs` should print `x86_64 arm64`, and the binary must not contain
   `DMDebugShow` (debug-only screens).
3. Put the app and an `Applications` symlink in a folder and run
   `hdiutil create -volname "aPhone Mirroring X.Y.Z" -srcfolder <folder> -format UDZO aPhone-Mirroring-X.Y.Z.dmg`.
4. `git tag -a vX.Y.Z -m "aPhone Mirroring X.Y.Z" && git push origin vX.Y.Z`, then
   `gh release create vX.Y.Z aPhone-Mirroring-X.Y.Z.dmg --title "aPhone Mirroring X.Y.Z" --notes-file notes.md --verify-tag`.
   The notes carry the CHANGELOG entry, the install steps (the app isn't
   notarized: System Settings › Privacy & Security › Open Anyway), and the
   DMG's SHA-256.
