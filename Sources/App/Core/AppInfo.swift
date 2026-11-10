import Foundation

enum AppInfo {
    /// The release this build was made from, e.g. 1.0.0-rc.3: build.sh writes it from the git tag
    /// (GHOSTBOX_RELEASE_VERSION). Other builds report the VERSION file.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "GhostBoxReleaseVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
