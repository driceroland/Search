import Foundation
import Security

/// This build's version and build number, as Info.plist has them.
enum Version {
    nonisolated static var number: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    nonisolated static var build: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }
}
