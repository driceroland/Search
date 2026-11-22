import Foundation
import Security

// What this app is, and which team signs the AI engine it may run.
//
// There is no updater here: this fork does not look for newer builds, fetch
// anything or swap its own bundle. A new version is built and installed by
// hand (build.sh).

enum Updater {
    /// What this app is: the version people read.
    nonisolated static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    nonisolated static var build: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// The team that signed this app, as the system reads it: the AI engine
    /// must come from the same one. Nil for an ad-hoc build, which then runs
    /// no engine outside a test run.
    nonisolated static var team: String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any]
        else { return nil }
        return signing[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Developer ID for a team, and the identifier when given.
    nonisolated static func developerID(team: String?, identifier: String?) -> SecRequirement? {
        guard let team else { return nil }
        let text = "anchor apple generic" + (identifier.map { " and identifier \"\($0)\"" } ?? "")
            + " and certificate 1[field.1.2.840.113635.100.6.2.6]"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13]"
            + " and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
}
