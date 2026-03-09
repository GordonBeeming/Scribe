import Foundation

struct AppVersion {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    static var versionBuild: String {
        "Version \(version) (\(build))"
    }

    static var commitHash: String {
        #if DEBUG
        return "dev"
        #else
        return Bundle.main.infoDictionary?["GitCommitHash"] as? String ?? "unknown"
        #endif
    }

    static var fullVersionString: String {
        "\(versionBuild) • \(commitHash)"
    }
}
