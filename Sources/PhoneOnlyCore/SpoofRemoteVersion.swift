import Foundation

/// Where this project lives on GitHub, so the Mac, the command line and
/// SpoofRemote all point at the same place for a newer version.
public enum Repository {
    /// owner/name, as in every link in the docs.
    public static let slug = "renyifan2009-hash/iOS-GPS-Spoofer-V1.2.3"
    /// The page a person opens to download the newest release.
    public static let releasesLatestURL = "https://github.com/\(slug)/releases/latest"
    /// GitHub's answer for the newest published release (its `tag_name`).
    public static let latestReleaseAPI = "https://api.github.com/repos/\(slug)/releases/latest"
}

/// A version of the SpoofRemote iPhone app: the version people see
/// (`CFBundleShortVersionString`, e.g. "1.1") and the build number
/// (`CFBundleVersion`, e.g. "3"), which goes up with every release.
///
/// The Mac reads the SpoofRemote installed on a connected iPhone and compares
/// it with the version that goes with this code, to tell when the iPhone app
/// is out of date. Shared, so the Mac app and the command line compare it the
/// same way.
public struct SpoofRemoteVersion: Equatable, Comparable, Sendable {
    /// The user-facing version as numbers: "1.1" is `[1, 1]`.
    public let marketing: [Int]
    /// The build number. It rises with every release, so it breaks ties.
    public let build: Int

    public init(marketing: [Int], build: Int) {
        self.marketing = marketing
        self.build = build
    }

    /// From what an app reports: the short version string ("1.1") and the
    /// build string ("3"). Both are read for the numbers in them, so "1.1.0"
    /// and a build of "3 (beta)" still work.
    public init(marketing: String, build: String) {
        self.marketing = Self.numbers(in: marketing)
        self.build = Self.numbers(in: build).first ?? 0
    }

    /// The numbers in a string, in order: "1.1" -> [1, 1], "v1.2.0" -> [1, 2, 0].
    static func numbers(in string: String) -> [Int] {
        string.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// For a message or a log line, e.g. "1.1 (3)".
    public var displayString: String {
        let version = marketing.isEmpty ? "?" : marketing.map(String.init).joined(separator: ".")
        return "\(version) (\(build))"
    }

    /// Compare the user-facing version first, number by number (a missing part
    /// counts as 0), then the build number.
    public static func < (a: SpoofRemoteVersion, b: SpoofRemoteVersion) -> Bool {
        let count = max(a.marketing.count, b.marketing.count)
        for index in 0..<count {
            let left = index < a.marketing.count ? a.marketing[index] : 0
            let right = index < b.marketing.count ? b.marketing[index] : 0
            if left != right { return left < right }
        }
        return a.build < b.build
    }

    /// Equal when neither is older, so a trailing zero doesn't matter
    /// (1.1 and 1.1.0 are the same version).
    public static func == (a: SpoofRemoteVersion, b: SpoofRemoteVersion) -> Bool {
        !(a < b) && !(b < a)
    }
}

/// The SpoofRemote iPhone app, as the Mac side needs to know it.
public enum SpoofRemote {
    /// SpoofRemote's bundle identifier, from iPhoneRemote/project.yml. The Mac
    /// looks for an app with this identifier on the iPhone.
    public static let bundleID = "com.iosgpsspoof.remote"

    /// The SpoofRemote version that goes with this code. A test checks it
    /// against iPhoneRemote/project.yml (MARKETING_VERSION and
    /// CURRENT_PROJECT_VERSION), so the two never drift apart. Bump the build
    /// here and in project.yml together when SpoofRemote changes.
    public static let expected = SpoofRemoteVersion(marketing: [1, 3, 3], build: 9)

    /// Where to send someone whose SpoofRemote is out of date.
    public static let releasesLatestURL = Repository.releasesLatestURL
}
