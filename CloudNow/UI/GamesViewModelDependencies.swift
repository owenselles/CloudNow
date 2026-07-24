import Foundation

nonisolated protocol GamesCatalogClient: Sendable {
    func fetchMainGames(
        token: String,
        streamingBaseUrl: String,
        vpcId: String?
    ) async throws -> [GameInfo]

    func fetchLibrary(
        token: String,
        streamingBaseUrl: String,
        vpcId: String?
    ) async throws -> [GameInfo]
}

extension GamesClient: GamesCatalogClient {}

nonisolated protocol MembershipClient: Sendable {
    func fetchVpcId(token: String, base: String) async throws -> String?
    func fetchSubscription(
        token: String,
        vpcId: String,
        userId: String
    ) async throws -> SubscriptionInfo
}

extension MESClient: MembershipClient {}

nonisolated protocol ActiveSessionsClient: Sendable {
    func getActiveSessions(
        token: String,
        base: String
    ) async throws -> [ActiveSessionInfo]
}

extension CloudMatchClient: ActiveSessionsClient {}

nonisolated protocol GamesPersistence: Actor {
    func loadGamesSnapshot() -> AppPersistenceStore.GamesSnapshot
    func saveFavoriteIds(_ ids: Set<String>)
    func savePreferredStoreIds(_ stores: [String: String])
    func saveRecentlyPlayedIds(_ ids: [String])
    func saveStreamSettings(_ settings: StreamSettings)
    func saveLastSession(_ session: LastSessionRecord?)
    func saveLibraryGames(_ games: [GameInfo])
    func saveSubscription(_ subscription: SubscriptionInfo)
    func saveVpcId(_ vpcId: String)
    func loadCatalog(localeCode: String, vpcId: String?) -> [GameInfo]?
    func saveCatalog(
        _ games: [GameInfo],
        localeCode: String,
        vpcId: String?
    )
}

extension AppPersistenceStore: GamesPersistence {}
