import Darwin
import Foundation
import Testing

@testable import Services

/// The Developer ID team check on the credential broker's peer (ADR-0046).
@Suite struct PeerCodeSignatureTests {
    @Test func requirementOnlyForWellFormedTeams() {
        #expect(
            PeerCodeSignature.requirement(team: "ABCDE12345")
                == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
        for bad in ["", "AB\"C", "ABC DE", "ABC) or (anchor apple", "ÄBCDE12345", String(repeating: "A", count: 21)] {
            #expect(PeerCodeSignature.requirement(team: bad) == nil)
        }
    }

    @Test func unsignedTestPeerFailsATeamRequirement() {
        // The test runner is not Developer ID signed, so it must not satisfy any team requirement.
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer {
            close(pair[0])
            close(pair[1])
        }
        #expect(!PeerCodeSignature.peer(pair[0], isSignedByTeam: "ABCDE12345"))
        #expect(!PeerCodeSignature.peer(pair[0], isSignedByTeam: "bad team"))
    }

    @Test func developmentBuildsHaveNoTeam() {
        // swift test binaries are ad-hoc/linker signed: the broker then relies on the path check alone.
        #expect(PeerCodeSignature.ownTeam == nil)
    }
}
