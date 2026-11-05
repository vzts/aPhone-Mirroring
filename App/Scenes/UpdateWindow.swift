import SharedModels
import SwiftUI

/// Software Update: asking to check automatically, and what a check found.
struct UpdateView: View {
  @ObservedObject var checker: UpdateChecker

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 64, height: 64)
      VStack(alignment: .leading, spacing: 12) {
        switch checker.panel {
        case .permission: permission
        case .result: result
        }
      }
    }
    .padding(20)
    .frame(width: 500)
  }

  // MARK: asking

  @ViewBuilder
  private var permission: some View {
    Text("Check for updates automatically?").font(.headline)
    Text("Should \(AppInfo.name) look for a new version on GitHub once a day? You can also check any time from the app menu.")
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    buttons {
      Button("Don't Check") { checker.allowAutomaticChecks(false) }
      Button("Check Automatically") { checker.allowAutomaticChecks(true) }.keyboardShortcut(.defaultAction)
    }
  }

  // MARK: result

  @ViewBuilder
  private var result: some View {
    switch checker.state {
    case .idle, .checking:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Checking for updates…")
      }
      .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    case .upToDate:
      Text("You're up to date!").font(.headline)
      Text("\(AppInfo.name) \(checker.current.description) is currently the newest version available.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      buttons { Button("OK") { checker.closeWindow() }.keyboardShortcut(.defaultAction) }
    case .failed:
      Text("Couldn't check for updates.").font(.headline)
      buttons {
        Button("Open Releases Page") { checker.openReleasesPage() }
        Button("OK") { checker.closeWindow() }.keyboardShortcut(.defaultAction)
      }
    case .available(let releases):
      available(releases)
    }
  }

  @ViewBuilder
  private func available(_ releases: [AppRelease]) -> some View {
    let newest = releases.first?.version?.description ?? releases.first?.tag ?? ""
    VStack(alignment: .leading, spacing: 4) {
      Text("A new version of \(AppInfo.name) is available!").font(.headline)
      Text("\(newest) is now available — you have \(checker.current.description).")
        .foregroundStyle(.secondary)
    }
    Text("What's new").font(.subheadline.weight(.semibold))
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        // Newest first; anyone further behind sees the latest few.
        ForEach(releases.prefix(5), id: \.tag) { release in
          VStack(alignment: .leading, spacing: 4) {
            Link(release.version?.description ?? release.tag, destination: release.page)
              .font(.callout.weight(.semibold))
            let highlights = release.highlights
            if highlights.isEmpty {
              Link("See the release notes on GitHub.", destination: release.page).font(.callout)
            }
            ForEach(Array(highlights.enumerated()), id: \.offset) { _, line in
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "•")
                Text(verbatim: line).lineLimit(3)
              }
              .font(.callout)
              .foregroundStyle(.secondary)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
    }
    .frame(height: 200)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    Text("The download opens in your browser. Drag the new version to Applications to replace this one.")
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    HStack {
      Button("Skip This Version") { checker.skipThisVersion() }
      Spacer()
      Button("Remind Me Later") { checker.remindLater() }.keyboardShortcut(.cancelAction)
      Button("Download") { checker.download() }.keyboardShortcut(.defaultAction)
    }
    .padding(.top, 4)
  }

  private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack { Spacer(minLength: 0); content() }.padding(.top, 4)
  }
}
