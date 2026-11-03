import SwiftUI
import ServiceManagement
import ScrcpyClient

struct SettingsView: View {
  @AppStorage("settings.tab") private var tab = "general"

  var body: some View {
    TabView(selection: $tab) {
      GeneralSettings()
        .tabItem { Label("General", systemImage: "gearshape") }
        .tag("general")
      MirrorSettings()
        .tabItem { Label("Mirroring", systemImage: "iphone.gen3") }
        .tag("mirror")
      AdvancedSettings()
        .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        .tag("advanced")
    }
  }
}

// MARK: General

private struct GeneralSettings: View {
  @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
  @AppStorage("mirror.autoOnConnect") private var autoMirror = true
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var loginError: String?

  private var openAtLogin: Binding<Bool> {
    Binding(
      get: { loginStatus == .enabled || loginStatus == .requiresApproval },
      set: { on in
        do {
          if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
          loginError = nil
        } catch {
          loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
      }
    )
  }

  var body: some View {
    Form {
      Section {
        Toggle("Open at login", isOn: openAtLogin)
        if loginStatus == .requiresApproval {
          LabeledContent {
            Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
          } label: {
            Text("Allow \(AppInfo.name) in Login Items to finish turning this on.")
              .foregroundStyle(.secondary)
          }
        }
        if let loginError {
          Text(loginError).font(.caption).foregroundStyle(.red)
        }
        Toggle("Show in menu bar", isOn: $showMenuBarIcon)
      } header: {
        Text("Startup")
      } footer: {
        Text("With the menu bar icon hidden, click \(AppInfo.name) in the Dock to reach your phones.")
      }

      Section {
        Toggle("Start mirroring when a phone connects", isOn: $autoMirror)
      } header: {
        Text("Connection")
      } footer: {
        Text("Phones you've mirrored before open on their own as soon as they connect.")
      }

      LanguageSection()
    }
    .formStyle(.grouped)
    .modifier(SettingsPane())
    .onAppear { loginStatus = SMAppService.mainApp.status }
  }
}

/// Follows the system by default; a choice here overrides it for this app only.
private struct LanguageSection: View {
  @State private var selection = AppLanguage.override ?? ""
  private let launched = AppLanguage.override ?? ""

  var body: some View {
    Section {
      Picker("Language", selection: $selection) {
        Text("System Default").tag("")
        ForEach(AppLanguage.supported, id: \.code) { language in
          Text(verbatim: language.name).tag(language.code)
        }
      }
      .onChange(of: selection) { _, code in AppLanguage.override = code.isEmpty ? nil : code }
      if selection != launched {
        LabeledContent {
          Button("Restart Now") { AppLanguage.relaunch() }
        } label: {
          Text("Restart \(AppInfo.name) to use the new language.")
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Language")
    }
  }
}

// MARK: Mirroring

private struct MirrorSettings: View {
  @AppStorage("mirror.codec") private var codec = "h265"
  @AppStorage("mirror.bitrate") private var bitrate = 8
  @AppStorage("mirror.maxFps") private var maxFps = 60
  @AppStorage("mirror.clipboardSync") private var clipboardSync = true
  @AppStorage("mirror.audioOutput") private var audioOutput = "mac"  // "mac" | "phone" | "none"

  private var bitrateValue: Binding<Double> {
    Binding(get: { Double(bitrate) }, set: { bitrate = Int($0.rounded()) })
  }

  var body: some View {
    Form {
      Section {
        Picker("Codec", selection: $codec) {
          Text("H.265 (recommended)").tag("h265")
          Text("H.264 (most compatible)").tag("h264")
          Text(verbatim: "AV1").tag("av1")
        }
        Picker("Frame rate", selection: $maxFps) {
          ForEach([30, 60, 90, 120], id: \.self) { Text(verbatim: "\($0)").tag($0) }
        }
        .pickerStyle(.segmented)
        LabeledContent("Bitrate") {
          HStack(spacing: 10) {
            Slider(value: bitrateValue, in: 1...24)
              .frame(maxWidth: 220)
            Text("\(bitrate) Mbps")
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .frame(width: 64, alignment: .trailing)
          }
        }
      } header: {
        Text("Video")
      } footer: {
        Text("A lower frame rate keeps the phone cooler; a higher bitrate keeps video and fast scrolling sharp. Open mirror windows reconnect for a moment to apply a change.")
      }

      Section("Audio") {
        Picker("Play sound on", selection: $audioOutput) {
          Text("Mac speakers").tag("mac")
          Text("Phone speakers / Bluetooth").tag("phone")
          Text("Mute").tag("none")
        }
      }

      Section {
        Toggle("Share clipboard with phone", isOn: $clipboardSync)
      } header: {
        Text("Clipboard")
      } footer: {
        Text("Text you copy on either device can be pasted on the other, including passwords.")
      }
    }
    .formStyle(.grouped)
    .modifier(SettingsPane())
    // Everything here applies to open mirror windows right away.
    .onChange(of: codec) { SessionCoordinator.shared.mirrorLaunchSettingsChanged() }
    .onChange(of: maxFps) { SessionCoordinator.shared.mirrorLaunchSettingsChanged() }
    .onChange(of: bitrate) { SessionCoordinator.shared.mirrorLaunchSettingsChanged() }
    .onChange(of: audioOutput) { SessionCoordinator.shared.mirrorLaunchSettingsChanged(refreshAudio: true) }
    .onChange(of: clipboardSync) { _, on in SessionCoordinator.shared.clipboardSyncChanged(on) }
  }
}

// MARK: Advanced

private struct AdvancedSettings: View {
  @State private var cleaning = false
  @State private var result: (message: String, ok: Bool)?

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
  }

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 6) {
          // The result sits beside the button, so the pane never changes height.
          HStack(spacing: 10) {
            Button {
              cleaning = true
              result = nil
              Task {
                do {
                  try await SessionCoordinator.shared.cleanupScrcpyServers()
                  result = (String(localized: "Removed leftover files from connected phones."), true)
                } catch {
                  result = (error.localizedDescription, false)
                }
                cleaning = false
              }
            } label: {
              Text(cleaning ? "Removing…" : "Remove Leftover Mirroring Files")
            }
            .disabled(cleaning)
            if let result {
              Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(result.ok ? .green : .red)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Text(verbatim: result.message))
            }
          }
          Text("Try this if mirroring fails with a protocol error. It deletes old copies of the mirroring server from connected phones.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } header: {
        Text("Troubleshooting")
      }

      Section("About") {
        LabeledContent("Version", value: appVersion)
        LabeledContent("Mirroring server", value: "scrcpy \(ScrcpyServerVersion.current)")
      }
    }
    .formStyle(.grouped)
    .modifier(SettingsPane())
  }
}

/// Fixed width, height from content — the window fits each tab instead of
/// leaving a tall empty area under short ones.
private struct SettingsPane: ViewModifier {
  func body(content: Content) -> some View {
    content
      .scrollDisabled(true)
      .frame(width: 520)
      .fixedSize(horizontal: false, vertical: true)
  }
}
