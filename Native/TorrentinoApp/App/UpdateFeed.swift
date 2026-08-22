import Foundation

/// The only source of the Sparkle appcast URL.
///
/// The release URL intentionally remains a placeholder until the WP19.H1 human
/// gate is complete. The release owner must replace `OWNER`, publish
/// `appcast.xml` as a GitHub Release asset at `releases/latest/download`, and
/// generate each release archive signature with Sparkle's `sign_update` using
/// the EdDSA private key paired with `SUPublicEDKey` in Info.plist. The appcast
/// and archive URLs must remain HTTPS-only. This delegate-provided URL avoids
/// a second, hardcoded `SUFeedURL` in Info.plist.
enum UpdateFeed {
    static let appcastURLString =
        "https://github.com/OWNER/Torrentino/releases/latest/download/appcast.xml"

    /// Failable so a malformed release-time edit cannot crash the app at
    /// startup; the checker treats an invalid value like the placeholder.
    static let appcastURL: URL? = URL(string: appcastURLString)

    static var isValidHTTPSGitHubURL: Bool {
        guard let url = appcastURL else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "github.com"
    }

    static var isPlaceholder: Bool {
        appcastURLString.contains("OWNER")
    }
}
