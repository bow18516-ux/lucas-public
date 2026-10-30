import XCTest
import Darwin
@testable import JaplosKernel

/// C2: the Team ID gate reads the peer's signature through Security.framework
/// instead of spawning `codesign` for every request.
final class TeamIdentityTests: XCTestCase {
    func testOwnTeamIDIsStableAndNonEmpty() {
        XCTAssertFalse(TeamIdentity.own.isEmpty)
        // Cached: repeated reads must not change or re-query.
        XCTAssertEqual(TeamIdentity.own, TeamIdentity.own)
    }

    func testPeerOnInvalidDescriptorIsNil() {
        XCTAssertNil(TeamIdentity.peer(of: -1))
    }

    func testPeerOnUnconnectedSocketIsNil() {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertNil(TeamIdentity.peer(of: descriptor))
    }
}
