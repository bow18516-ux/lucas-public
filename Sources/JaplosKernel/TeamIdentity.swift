import Darwin
import Foundation
import Security

/// Team ID resolution without spawning `codesign`.
///
/// The audit token the kernel attaches to a Unix-socket connection identifies
/// the peer process, and Security.framework can read its signature from there.
/// Spawning `/usr/bin/codesign` per request was both slow and a subprocess per
/// ping; this is a direct syscall-level query.
enum TeamIdentity {
    /// `LOCAL_PEERTOKEN` (0x006) on Darwin returns the peer's audit token.
    private static let localPeerToken: Int32 = 0x006

    /// Resolved once per process: the daemon's own signature never changes.
    static let own: String = readOwnTeamID() ?? "adhoc"

    /// Team ID of the process on the other end of `client`, or `nil` when the
    /// peer cannot be identified (for example an unsigned build).
    static func peer(of client: Int32) -> String? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let result = getsockopt(client, 0 /* SOL_LOCAL */, localPeerToken, &token, &length)
        guard result == 0, length > 0 else { return nil }

        let data = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: data] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code
        else { return nil }

        return teamID(of: code)
    }

    private static func teamID(of code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSDynamicInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let info = information as? [String: Any]
        else { return nil }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        guard let team, !team.isEmpty else { return nil }
        return team
    }

    private static func readOwnTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return teamID(of: code)
    }
}
