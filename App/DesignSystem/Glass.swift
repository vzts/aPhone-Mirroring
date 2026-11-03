import AppKit
import SwiftUI

// Liquid Glass on macOS 26+, materials before that. Every surface that floats
// over content (mirror chrome, connect screen cards) goes through here so the
// two looks stay in sync.

extension View {
  /// Rounded glass panel.
  @ViewBuilder
  func glassPanel(cornerRadius: CGFloat = 18) -> some View {
    if #available(macOS 26.0, *) {
      glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    } else {
      background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
  }

  /// Filled call-to-action button. Custom rather than `.borderedProminent` /
  /// `.glassProminent`: those turn grey whenever the app isn't active, which
  /// is always the case in the menu bar panel, so Mirror looked disabled.
  func primaryButtonStyle() -> some View {
    buttonStyle(AccentButtonStyle())
  }

  /// Quiet secondary button that still reads as a button.
  @ViewBuilder
  func secondaryButtonStyle() -> some View {
    if #available(macOS 26.0, *) {
      buttonStyle(.glass)
    } else {
      buttonStyle(.bordered)
    }
  }
}

struct AccentButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    AccentButtonBody(configuration: configuration)
  }

  private struct AccentButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
      configuration.label
        .font(font)
        .foregroundStyle(.white)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background {
          Capsule(style: .continuous)
            .fill(Color.accentColor.gradient)
            .brightness(configuration.isPressed ? -0.12 : 0)
        }
        .overlay {
          Capsule(style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Capsule())
    }

    private var font: Font {
      switch controlSize {
      case .mini, .small: return .callout.weight(.semibold)
      case .large, .extraLarge: return .body.weight(.semibold)
      default: return .body.weight(.medium)
      }
    }

    private var horizontalPadding: CGFloat {
      switch controlSize {
      case .mini, .small: return 12
      case .large, .extraLarge: return 20
      default: return 16
      }
    }

    private var verticalPadding: CGFloat {
      switch controlSize {
      case .mini, .small: return 4
      case .large, .extraLarge: return 10
      default: return 6
      }
    }
  }
}

/// Android release name for an SDK level, e.g. 36 → "Android 16".
func androidVersionName(sdk: Int) -> String {
  let names: [Int: String] = [
    28: "9", 29: "10", 30: "11", 31: "12", 32: "12L", 33: "13",
    34: "14", 35: "15", 36: "16", 37: "17",
  ]
  guard sdk > 0 else { return "Android" }
  if let name = names[sdk] { return "Android \(name)" }
  return "Android (API \(sdk))"
}
