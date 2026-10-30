import Foundation

/// A newer release offered by `clamshell update --json`.
public struct ReleaseInfo: Equatable, Sendable {
    /// Bare version, for example `0.4.0`.
    public let version: String
    /// Git tag, for example `v0.4.0`.
    public let tag: String
    /// Human-readable release title.
    public let name: String
    /// Whether GitHub marks the release as a pre-release.
    public let isPrerelease: Bool
    /// Release page, opened for the full notes.
    public let pageURL: String
    /// Installer file name.
    public let assetName: String
    /// Whether the release carries a checksum to verify the installer against.
    public let hasDigest: Bool

    public init(
        version: String,
        tag: String,
        name: String,
        isPrerelease: Bool,
        pageURL: String,
        assetName: String,
        hasDigest: Bool
    ) {
        self.version = version
        self.tag = tag
        self.name = name
        self.isPrerelease = isPrerelease
        self.pageURL = pageURL
        self.assetName = assetName
        self.hasDigest = hasDigest
    }
}

/// The result of an update check.
///
/// Decoded from `clamshell update --json`. A failed check is a normal state: it
/// carries `error` with `release` absent, so the menu can say "could not check"
/// instead of treating an offline machine as an error to alert on.
public struct UpdateStatus: Equatable, Sendable {
    /// The version the check compared against.
    public let current: String
    /// Newest version seen, or `nil` when nothing was reported.
    public let latest: String?
    /// The release to offer, or `nil` when already up to date.
    public let release: ReleaseInfo?
    /// Epoch seconds of the check that produced this result.
    public let checkedAt: Int
    /// Whether the result was served from the local cache.
    public let fromCache: Bool
    /// Reason the check failed, or `nil` on success.
    public let error: String?

    public init(
        current: String,
        latest: String?,
        release: ReleaseInfo?,
        checkedAt: Int,
        fromCache: Bool,
        error: String? = nil
    ) {
        self.current = current
        self.latest = latest
        self.release = release
        self.checkedAt = checkedAt
        self.fromCache = fromCache
        self.error = error
    }

    /// Whether a newer release is available to install.
    public var updateAvailable: Bool {
        release != nil
    }

    /// Whether the last check failed to reach the release list.
    public var failed: Bool {
        error != nil
    }
}

/// Decoding for `clamshell update --json`.
///
/// Hand-written for the same reason as `ClamshellStatus`: every field must
/// degrade to a safe value, so a missing key or an `error`-only response never
/// fails the whole decode and hides an otherwise usable answer.
extension UpdateStatus: Decodable {
    private enum CodingKeys: String, CodingKey {
        case current
        case latest
        case updateAvailable
        case checkedAt
        case fromCache
        case error
        case release
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = try container.decodeIfPresent(String.self, forKey: .current) ?? "unknown"
        latest = try container.decodeIfPresent(String.self, forKey: .latest)
        checkedAt = try container.decodeIfPresent(Int.self, forKey: .checkedAt) ?? 0
        fromCache = try container.decodeIfPresent(Bool.self, forKey: .fromCache) ?? false
        error = try container.decodeIfPresent(String.self, forKey: .error)
        release = try container.decodeIfPresent(ReleaseInfo.self, forKey: .release)
    }
}

/// Decoding for a release inside the update payload.
extension ReleaseInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case version
        case tag
        case name
        case isPrerelease = "prerelease"
        case pageURL = "pageUrl"
        case assetName
        case hasDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        tag = try container.decodeIfPresent(String.self, forKey: .tag) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        isPrerelease = try container.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
        pageURL = try container.decodeIfPresent(String.self, forKey: .pageURL) ?? ""
        assetName = try container.decodeIfPresent(String.self, forKey: .assetName) ?? ""
        hasDigest = try container.decodeIfPresent(Bool.self, forKey: .hasDigest) ?? false
    }
}

/// Turns an update status into the strings the menu shows.
public enum UpdatePresentation {
    /// Title of the menu row that installs a known update.
    ///
    /// Returns `nil` when there is nothing to install, so the caller can hide
    /// the row rather than show a dead entry.
    public static func updateTitle(for status: UpdateStatus?) -> String? {
        guard let release = status?.release else { return nil }
        let suffix = release.isPrerelease ? " (beta)" : ""
        return "Update to \(release.version)\(suffix)…"
    }

    /// Title of the always-present manual check row.
    public static func checkTitle(for status: UpdateStatus?) -> String {
        guard let status, status.failed else { return "Check for Updates…" }
        return "Check for Updates… (last check failed)"
    }

    /// One-line summary for the consent dialog.
    public static func consentMessage(for release: ReleaseInfo, current: String) -> String {
        let kind = release.isPrerelease ? "pre-release" : "release"
        var lines = ["Clamshell \(release.version) is available; you have \(current)."]
        lines.append("This is a \(kind).")
        lines.append(
            release.hasDigest
                ? "The installer checksum will be verified before installing."
                : "This release carries no checksum to verify."
        )
        lines.append("Installing needs one administrator approval.")
        return lines.joined(separator: "\n")
    }
}
