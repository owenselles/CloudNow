import Foundation

/// Credential boundary shared by future Xbox catalog and session adapters.
/// Implementations return a short-lived value only when an account identifier,
/// relying party, and expiry all match.
nonisolated protocol XboxXSTSCredentialProviding: Sendable {
    func credential(
        for account: XboxCloudAuthorizedAccount,
        relyingParty: XboxLiveRelyingParty
    ) async throws -> XboxXSTSCredential
}

/// Bounded, process-memory-only XSTS storage. Signing out or deinitializing the
/// app drops all derived Xbox credentials; none are written to Keychain or disk.
actor XboxLiveCredentialVault: XboxXSTSCredentialProviding, XboxLocalCredentialLifecycle {
    private static let maximumAuthorizationCount = 2
    private static let maximumEnrichmentRelyingPartyCount = 8

    private struct PendingEnrichment: Sendable {
        let relyingParties: Set<XboxLiveRelyingParty>
        let task: Task<Void, Never>
    }

    private struct StoredAuthorization: Sendable {
        let sequence: UInt64
        var credentials: [XboxLiveRelyingParty: XboxXSTSCredential]
        var pendingEnrichment: PendingEnrichment?
    }

    private let now: @Sendable () -> Date
    private var nextSequence: UInt64 = 0
    private var authorizations: [String: StoredAuthorization] = [:]

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    deinit {
        for authorization in authorizations.values {
            authorization.pendingEnrichment?.task.cancel()
        }
    }

    func store(
        identifier: String,
        credentials: [XboxXSTSCredential],
        accountMetadataRelyingParties: Set<XboxLiveRelyingParty>? = nil,
        enrichmentRelyingParties: Set<XboxLiveRelyingParty> = [],
        requestEnrichment: (@Sendable () async -> [XboxXSTSCredential])? = nil
    ) throws -> XboxCloudAuthorizedAccount {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIdentifier.isEmpty,
              normalizedIdentifier.utf8.count <= 256,
              !credentials.isEmpty
        else {
            throw XboxLiveAuthorizationError.invalidPayload
        }

        var credentialsByRelyingParty: [XboxLiveRelyingParty: XboxXSTSCredential] = [:]
        for credential in credentials {
            guard credential.isUsable(at: now()),
                  credentialsByRelyingParty.updateValue(
                      credential,
                      forKey: credential.relyingParty
                  ) == nil
            else {
                throw XboxLiveAuthorizationError.invalidPayload
            }
        }

        let metadataRelyingParties = accountMetadataRelyingParties
            ?? Set(credentialsByRelyingParty.keys)
        let metadataCredentials = credentials.filter {
            metadataRelyingParties.contains($0.relyingParty)
        }
        guard !metadataRelyingParties.isEmpty,
              metadataCredentials.count == metadataRelyingParties.count,
              let expiresAt = metadataCredentials.map(\.expiresAt).min()
        else {
            throw XboxLiveAuthorizationError.invalidPayload
        }
        let displayName = metadataCredentials.lazy.compactMap(\.gamertag).first

        guard enrichmentRelyingParties.count <= Self.maximumEnrichmentRelyingPartyCount,
              enrichmentRelyingParties.isDisjoint(with: credentialsByRelyingParty.keys),
              enrichmentRelyingParties.isEmpty == (requestEnrichment == nil)
        else {
            throw XboxLiveAuthorizationError.invalidPayload
        }

        nextSequence &+= 1
        let sequence = nextSequence
        authorizations[normalizedIdentifier]?.pendingEnrichment?.task.cancel()
        authorizations[normalizedIdentifier] = StoredAuthorization(
            sequence: nextSequence,
            credentials: credentialsByRelyingParty,
            pendingEnrichment: nil
        )

        if let requestEnrichment {
            let task = Task { @concurrent [weak self] in
                let enrichedCredentials = await requestEnrichment()
                guard !Task.isCancelled else { return }
                await self?.completeEnrichment(
                    identifier: normalizedIdentifier,
                    sequence: sequence,
                    relyingParties: enrichmentRelyingParties,
                    credentials: enrichedCredentials
                )
            }
            authorizations[normalizedIdentifier]?.pendingEnrichment = PendingEnrichment(
                relyingParties: enrichmentRelyingParties,
                task: task
            )
        }
        trimIfNeeded()

        return XboxCloudAuthorizedAccount(
            authorizationIdentifier: normalizedIdentifier,
            displayName: displayName,
            expiresAt: expiresAt
        )
    }

    func credential(
        for account: XboxCloudAuthorizedAccount,
        relyingParty: XboxLiveRelyingParty
    ) async throws -> XboxXSTSCredential {
        guard account.isUsable(at: now()) else {
            throw XboxLiveAuthorizationError.credentialExpired
        }
        guard let authorization = authorizations[account.authorizationIdentifier] else {
            throw XboxLiveAuthorizationError.accountNotAuthorized
        }
        if let credential = authorization.credentials[relyingParty] {
            guard credential.isUsable(at: now()) else {
                throw XboxLiveAuthorizationError.credentialExpired
            }
            return credential
        }

        guard let pendingEnrichment = authorization.pendingEnrichment,
              pendingEnrichment.relyingParties.contains(relyingParty)
        else {
            throw XboxLiveAuthorizationError.credentialUnavailable(relyingParty)
        }

        try Task.checkCancellation()
        await pendingEnrichment.task.value
        try Task.checkCancellation()

        guard account.isUsable(at: now()) else {
            throw XboxLiveAuthorizationError.credentialExpired
        }
        guard let enrichedAuthorization = authorizations[account.authorizationIdentifier] else {
            throw XboxLiveAuthorizationError.accountNotAuthorized
        }
        guard let credential = enrichedAuthorization.credentials[relyingParty] else {
            throw XboxLiveAuthorizationError.credentialUnavailable(relyingParty)
        }
        guard credential.isUsable(at: now()) else {
            throw XboxLiveAuthorizationError.credentialExpired
        }
        return credential
    }

    func remove(account: XboxCloudAuthorizedAccount) {
        authorizations[account.authorizationIdentifier]?.pendingEnrichment?.task.cancel()
        authorizations.removeValue(forKey: account.authorizationIdentifier)
    }

    func clearLocalCredentials() {
        for authorization in authorizations.values {
            authorization.pendingEnrichment?.task.cancel()
        }
        authorizations.removeAll(keepingCapacity: false)
    }

    private func completeEnrichment(
        identifier: String,
        sequence: UInt64,
        relyingParties: Set<XboxLiveRelyingParty>,
        credentials: [XboxXSTSCredential]
    ) {
        guard var authorization = authorizations[identifier],
              authorization.sequence == sequence,
              authorization.pendingEnrichment?.relyingParties == relyingParties
        else {
            return
        }
        authorization.pendingEnrichment = nil

        let userHashes = Set(authorization.credentials.values.map(\.userHash))
        if userHashes.count == 1, let expectedUserHash = userHashes.first {
            for credential in credentials where
                relyingParties.contains(credential.relyingParty)
                && credential.userHash == expectedUserHash
                && credential.isUsable(at: now())
                && authorization.credentials[credential.relyingParty] == nil
            {
                authorization.credentials[credential.relyingParty] = credential
            }
        }
        authorizations[identifier] = authorization
    }

    private func trimIfNeeded() {
        while authorizations.count > Self.maximumAuthorizationCount,
              let oldestIdentifier = authorizations.min(
                  by: { $0.value.sequence < $1.value.sequence }
              )?.key
        {
            authorizations[oldestIdentifier]?.pendingEnrichment?.task.cancel()
            authorizations.removeValue(forKey: oldestIdentifier)
        }
    }
}

/// Converts a generic Microsoft OAuth result into Xbox Cloud-scoped XSTS
/// credentials, then hands only an opaque account handle to application state.
nonisolated struct XboxLiveAccountAuthorizationClient: XboxCloudAccountAuthorizationClient {
    private static let maximumRelyingPartyCount = 8

    let credentialVault: XboxLiveCredentialVault

    private let tokenClient: XboxLiveTokenClient
    private let requiredRelyingParties: [XboxLiveRelyingParty]
    private let optionalRelyingParties: [XboxLiveRelyingParty]
    private let now: @Sendable () -> Date
    private let makeAuthorizationIdentifier: @Sendable () -> String

    init(
        tokenClient: XboxLiveTokenClient,
        credentialVault: XboxLiveCredentialVault,
        relyingParties: [XboxLiveRelyingParty] = [.cloudGaming],
        optionalRelyingParties: [XboxLiveRelyingParty] = [],
        now: @escaping @Sendable () -> Date = { Date() },
        makeAuthorizationIdentifier: @escaping @Sendable () -> String = {
            UUID().uuidString
        }
    ) throws {
        let configuredRelyingParties = relyingParties + optionalRelyingParties
        guard !relyingParties.isEmpty,
              configuredRelyingParties.count <= Self.maximumRelyingPartyCount,
              Set(configuredRelyingParties).count == configuredRelyingParties.count
        else {
            throw XboxLiveAuthorizationError.invalidConfiguration(
                "Xbox relying-party requirements are invalid."
            )
        }
        self.tokenClient = tokenClient
        self.credentialVault = credentialVault
        requiredRelyingParties = relyingParties
        self.optionalRelyingParties = optionalRelyingParties
        self.now = now
        self.makeAuthorizationIdentifier = makeAuthorizationIdentifier
    }

    func authorize(
        microsoftToken: MicrosoftOAuthToken
    ) async throws -> XboxCloudAuthorizedAccount {
        guard !microsoftToken.accessToken.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw XboxLiveAuthorizationError.invalidMicrosoftToken
        }
        guard microsoftToken.expiresAt > now() else {
            throw XboxLiveAuthorizationError.microsoftTokenExpired
        }

        let userToken = try await tokenClient.requestUserToken(
            microsoftAccessToken: microsoftToken.accessToken
        )
        let requiredCredentials = try await requestRequiredCredentials(
            userToken: userToken
        )

        try Task.checkCancellation()
        let tokenClient = tokenClient
        let optionalRelyingParties = optionalRelyingParties
        let requestEnrichment = Self.makeOptionalCredentialRequest(
            tokenClient: tokenClient,
            userToken: userToken,
            relyingParties: optionalRelyingParties
        )
        return try await credentialVault.store(
            identifier: makeAuthorizationIdentifier(),
            credentials: requiredCredentials,
            accountMetadataRelyingParties: Set(requiredRelyingParties),
            enrichmentRelyingParties: Set(optionalRelyingParties),
            requestEnrichment: requestEnrichment
        )
    }

    private static func makeOptionalCredentialRequest(
        tokenClient: XboxLiveTokenClient,
        userToken: XboxUserToken,
        relyingParties: [XboxLiveRelyingParty]
    ) -> (@Sendable () async -> [XboxXSTSCredential])? {
        guard !relyingParties.isEmpty else { return nil }
        return {
            await requestOptionalCredentials(
                tokenClient: tokenClient,
                userToken: userToken,
                relyingParties: relyingParties
            )
        }
    }

    private func requestRequiredCredentials(
        userToken: XboxUserToken
    ) async throws -> [XboxXSTSCredential] {
        try await withThrowingTaskGroup(
            of: XboxXSTSCredential.self,
            returning: [XboxXSTSCredential].self
        ) { group in
            for relyingParty in requiredRelyingParties {
                group.addTask {
                    try await tokenClient.requestXSTSCredential(
                        userToken: userToken,
                        relyingParty: relyingParty
                    )
                }
            }

            var credentials: [XboxXSTSCredential] = []
            credentials.reserveCapacity(requiredRelyingParties.count)
            for try await credential in group {
                credentials.append(credential)
            }
            return credentials
        }
    }

    private static func requestOptionalCredentials(
        tokenClient: XboxLiveTokenClient,
        userToken: XboxUserToken,
        relyingParties: [XboxLiveRelyingParty]
    ) async -> [XboxXSTSCredential] {
        await withTaskGroup(
            of: XboxXSTSCredential?.self,
            returning: [XboxXSTSCredential].self
        ) { group in
            for relyingParty in relyingParties {
                group.addTask {
                    try? await tokenClient.requestXSTSCredential(
                        userToken: userToken,
                        relyingParty: relyingParty
                    )
                }
            }

            var credentials: [XboxXSTSCredential] = []
            credentials.reserveCapacity(relyingParties.count)
            for await credential in group {
                if let credential {
                    credentials.append(credential)
                }
            }
            return credentials
        }
    }

    /// Drops every derived Xbox credential while leaving the separately owned
    /// Microsoft OAuth session lifecycle to `XboxAuthManager`.
    func clearLocalCredentials() async {
        await credentialVault.clearLocalCredentials()
    }
}
