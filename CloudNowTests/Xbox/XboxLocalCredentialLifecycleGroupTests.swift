@testable import CloudNow
import Foundation
import Testing

@Suite("Xbox local credential lifecycle group")
struct XboxLocalCredentialLifecycleGroupTests {
    @Test("Every memory-only credential owner is cleared")
    func clearsEveryOwner() async {
        let first = XboxCredentialLifecycleProbe()
        let second = XboxCredentialLifecycleProbe()
        let group = XboxLocalCredentialLifecycleGroup([first, second])

        await group.clearLocalCredentials()

        #expect(await first.clearCount == 1)
        #expect(await second.clearCount == 1)
    }

    @Test("Inactive-provider cleanup purges XSTS and cached GS credentials")
    func purgesDerivedCredentialsAndSessions() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let vault = XboxLiveCredentialVault(now: { now })
        let account = try await vault.store(
            identifier: "fixture-account",
            credentials: [
                XboxXSTSCredential(
                    token: "fixture-xsts",
                    userHash: "fixture-user-hash",
                    relyingParty: .cloudGaming,
                    expiresAt: now.addingTimeInterval(3600),
                    gamertag: "Fixture Player"
                ),
            ]
        )
        let transport = RecordingHTTPTransport { request, index in
            #expect(index == 0)
            #expect(request.url?.host == "xgpuweb.gssv-play-prod.xboxlive.com")
            return StubbedHTTPResponse(json: Self.gsLoginResponse)
        }
        let provider = try XboxCloudGSSessionProvider(
            credentialProvider: vault,
            configuration: .microsoftProduction(),
            transport: transport,
            now: { now }
        )
        _ = try await provider.session(for: account)
        #expect(await transport.requests().count == 1)

        let lifecycle = XboxLocalCredentialLifecycleGroup([vault, provider])
        await lifecycle.clearLocalCredentials()

        await #expect(throws: XboxLiveAuthorizationError.accountNotAuthorized) {
            _ = try await vault.credential(
                for: account,
                relyingParty: .cloudGaming
            )
        }
        await #expect(throws: XboxLiveAuthorizationError.accountNotAuthorized) {
            _ = try await provider.session(for: account)
        }
        #expect(await transport.requests().count == 1)
    }

    private static let gsLoginResponse = #"""
    {
      "gsToken": "fixture-gs-token",
      "durationInSeconds": 3600,
      "market": "US",
      "offeringSettings": {
        "regions": [{
          "name": "West US",
          "baseUri": "https://wus.gssv-play-prod.xboxlive.com",
          "isDefault": true,
          "fallbackPriority": -1,
          "systemUpdateGroups": []
        }]
      }
    }
    """#
}

private actor XboxCredentialLifecycleProbe: XboxLocalCredentialLifecycle {
    private(set) var clearCount = 0

    func clearLocalCredentials() {
        clearCount += 1
    }
}
