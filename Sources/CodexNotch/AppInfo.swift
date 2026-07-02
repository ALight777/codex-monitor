import Foundation

enum AppInfo {
    static let version = "0.1.3"

    static var displayVersion: String {
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmedVersion = bundleVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedVersion.isEmpty ? version : trimmedVersion
    }
}
