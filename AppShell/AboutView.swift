import SwiftUI
import AppKit

/// The About card (menu-bar → Settings group). A small, fixed-size panel showing the
/// app icon, name, version + build, and copyright — all read from the bundle so there's
/// a single source of truth (project.yml → Info.plist). Deliberately sparse for v1;
/// the homepage link and a "Check for Updates…" action are planned follow-ups (see
/// [[sparkle-and-versioning]]) and slot into `footer` when ready.
struct AboutView: View {
    var updater = UpdaterController.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                // Decorative: the app name is spelled out in the Text directly below it.
                .accessibilityHidden(true)

            Text(Self.appName)
                .font(.title2.weight(.semibold))

            Text(Self.versionLine)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let copyright = Self.copyright {
                Text(copyright)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            Link("Homepage", destination: Self.homepage)
                .font(.callout)

            // Sparkle (docs/14 §Sparkle) — disabled while a check/install is in flight.
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(width: 320)
    }

    // MARK: Bundle-sourced strings

    private static var appName: String {
        info("CFBundleDisplayName") ?? info("CFBundleName") ?? "MagicButtons"
    }

    /// "Version 1.1.0 (2)" — marketing version with the build number in parentheses.
    private static var versionLine: String {
        let short = info("CFBundleShortVersionString") ?? "—"
        if let build = info("CFBundleVersion"), build != short {
            return String(localized: "Version \(short) (\(build))",
                          comment: "About card version line: first %@ is the marketing version, second is the build number.")
        }
        return String(localized: "Version \(short)",
                      comment: "About card version line when the build number matches the marketing version.")
    }

    private static var copyright: String? { info("NSHumanReadableCopyright") }

    private static let homepage = URL(string: "https://codeberg.org/gentleworks/MagicButtons")!

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
