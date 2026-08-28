@testable import CloudNow
import CoreGraphics
import Foundation
import Testing

@Suite("Artwork image pipeline cache")
struct ArtworkImagePipelineTests {
    enum SuspendedArtworkEvent: CaseIterable, Sendable {
        case streaming
        case background

        func apply(to pipeline: ArtworkImagePipeline) async {
            switch self {
            case .streaming:
                await pipeline.handleMemoryEvent(.streaming)
            case .background:
                await pipeline.handleMemoryEvent(.background)
            }
        }
    }

    @Test("Count limit evicts the least recently used image")
    func countLimitUsesLRU() async throws {
        let image = try makeImage(width: 2, height: 2)
        let loader = RecordingArtworkLoader(image: image)
        let budget = ArtworkImagePipeline.CacheBudget(
            totalCostLimit: Int.max,
            countLimit: 2
        )
        let pipeline = makePipeline(loader: loader, budget: budget)
        let urls = try testURLs()

        _ = try await pipeline.image(for: urls[0], maxPixelSize: 320)
        _ = try await pipeline.image(for: urls[1], maxPixelSize: 320)
        _ = try await pipeline.image(for: urls[0], maxPixelSize: 320)
        _ = try await pipeline.image(for: urls[2], maxPixelSize: 320)
        _ = try await pipeline.image(for: urls[1], maxPixelSize: 320)

        let requests = await loader.requestedURLs()
        let snapshot = await pipeline.snapshot(maxPixelSize: 320)
        #expect(requests.map(\.lastPathComponent) == ["a", "b", "c", "b"])
        #expect(snapshot.cachedImageCount == 2)
        #expect(snapshot.totalCost == image.bytesPerRow * image.height * 2)
    }

    @Test("Cost limit evicts images even when count budget has room")
    func costLimitEvicts() async throws {
        let image = try makeImage(width: 2, height: 2)
        let loader = RecordingArtworkLoader(image: image)
        let imageCost = image.bytesPerRow * image.height
        let budget = ArtworkImagePipeline.CacheBudget(
            totalCostLimit: imageCost,
            countLimit: 10
        )
        let pipeline = makePipeline(loader: loader, budget: budget)
        let urls = try testURLs()

        _ = try await pipeline.image(for: urls[0], maxPixelSize: 320)
        _ = try await pipeline.image(for: urls[1], maxPixelSize: 320)
        _ = try await pipeline.image(for: urls[0], maxPixelSize: 320)

        let requests = await loader.requestedURLs()
        let snapshot = await pipeline.snapshot(maxPixelSize: 320)
        #expect(requests.map(\.lastPathComponent) == ["a", "b", "a"])
        #expect(snapshot.cachedImageCount == 1)
        #expect(snapshot.totalCost == imageCost)
    }

    @Test("Duplicate in-flight requests share one loader task")
    func duplicateRequestsCoalesce() async throws {
        let image = try makeImage(width: 3, height: 2)
        let loader = GatedArtworkLoader(image: image)
        let pipeline = makePipeline(loader: loader)
        let url = try testURLs()[0]

        let first = Task {
            try await pipeline.image(for: url, maxPixelSize: 320)
        }
        await loader.waitForCallCount(1)
        let second = Task {
            try await pipeline.image(for: url, maxPixelSize: 320)
        }

        let registered = await waitForWaiterCount(
            2,
            pipeline: pipeline,
            maxPixelSize: 320
        )
        let callCount = await loader.callCount()
        #expect(registered)
        #expect(callCount == 1)

        await loader.releaseAll()
        let firstImage = try await first.value
        let secondImage = try await second.value
        let snapshot = await pipeline.snapshot(maxPixelSize: 320)
        #expect(firstImage.width == 3)
        #expect(secondImage.width == 3)
        #expect(snapshot.cachedImageCount == 1)
    }

    @Test("A failed load is removed so the next request can retry")
    func failureDoesNotPoisonRetry() async throws {
        let image = try makeImage(width: 2, height: 2)
        let loader = RecordingArtworkLoader(image: image, failuresRemaining: 1)
        let pipeline = makePipeline(loader: loader)
        let url = try testURLs()[0]

        await #expect(throws: ArtworkLoaderTestError.self) {
            _ = try await pipeline.image(for: url, maxPixelSize: 320)
        }
        _ = try await pipeline.image(for: url, maxPixelSize: 320)
        _ = try await pipeline.image(for: url, maxPixelSize: 320)

        let requests = await loader.requestedURLs()
        let snapshot = await pipeline.snapshot(maxPixelSize: 320)
        #expect(requests.count == 2)
        #expect(snapshot.cachedImageCount == 1)
        #expect(snapshot.inFlightRequestCount == 0)
        #expect(snapshot.waiterCount == 0)
    }

    @Test("Ephemeral artwork uses a separate loader and decoded cache key")
    func ephemeralArtworkStaysOffTheSharedNetworkCachePath() async throws {
        let image = try makeImage(width: 2, height: 2)
        let sharedLoader = RecordingArtworkLoader(image: image)
        let ephemeralLoader = RecordingArtworkLoader(image: image)
        let pipeline = ArtworkImagePipeline(
            imageLoader: { url, maxPixelSize in
                try await sharedLoader.load(
                    url: url,
                    maxPixelSize: maxPixelSize
                )
            },
            ephemeralImageLoader: { url, maxPixelSize in
                try await ephemeralLoader.load(
                    url: url,
                    maxPixelSize: maxPixelSize
                )
            }
        )
        let url = try testURLs()[0]

        _ = try await pipeline.image(for: url, maxPixelSize: 320)
        _ = try await pipeline.image(
            for: url,
            maxPixelSize: 320,
            networkCachePolicy: .ephemeral
        )
        _ = try await pipeline.image(
            for: url,
            maxPixelSize: 320,
            networkCachePolicy: .ephemeral
        )

        #expect(await sharedLoader.requestedURLs() == [url])
        #expect(await ephemeralLoader.requestedURLs() == [url])
        #expect(await pipeline.snapshot(maxPixelSize: 320).cachedImageCount == 2)
    }

    @Test("Cancelling a waiter removes it without cancelling shared work")
    func waiterCancellationCleansUp() async throws {
        let image = try makeImage(width: 2, height: 2)
        let loader = GatedArtworkLoader(image: image)
        let pipeline = makePipeline(loader: loader)
        let url = try testURLs()[0]
        let cancelledWaiter = Task {
            try await pipeline.image(for: url, maxPixelSize: 320)
        }

        await loader.waitForCallCount(1)
        let initialWaiterRegistered = await waitForWaiterCount(
            1,
            pipeline: pipeline,
            maxPixelSize: 320
        )
        #expect(initialWaiterRegistered)
        cancelledWaiter.cancel()
        let cancelledWaiterRemoved = await waitForWaiterCount(
            0,
            pipeline: pipeline,
            maxPixelSize: 320
        )
        #expect(cancelledWaiterRemoved)
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledWaiter.value
        }

        let replacementWaiter = Task {
            try await pipeline.image(for: url, maxPixelSize: 320)
        }
        let replacementRegistered = await waitForWaiterCount(
            1,
            pipeline: pipeline,
            maxPixelSize: 320
        )
        let callCount = await loader.callCount()
        #expect(replacementRegistered)
        #expect(callCount == 1)

        await loader.releaseAll()
        _ = try await replacementWaiter.value
        let snapshot = await pipeline.snapshot(maxPixelSize: 320)
        #expect(snapshot.cachedImageCount == 1)
        #expect(snapshot.inFlightRequestCount == 0)
        #expect(snapshot.waiterCount == 0)
    }

    @Test("Lifecycle events retain, trim, and evict the intended artwork")
    func lifecycleCachePolicy() async throws {
        let image = try makeImage(width: 2, height: 2)
        let loader = RecordingArtworkLoader(image: image)
        let pipeline = makePipeline(
            loader: loader,
            budget: ArtworkImagePipeline.CacheBudget(
                totalCostLimit: .max,
                countLimit: 3
            ),
            backgroundBudget: ArtworkImagePipeline.CacheBudget(
                totalCostLimit: .max,
                countLimit: 1
            ),
            heroBudget: ArtworkImagePipeline.CacheBudget(
                totalCostLimit: .max,
                countLimit: 2
            )
        )
        let urls = try testURLs()

        _ = try await pipeline.image(
            for: urls[0],
            maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
        )
        _ = try await pipeline.image(
            for: urls[1],
            maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
        )
        _ = try await pipeline.image(
            for: urls[2],
            maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
        )
        _ = try await pipeline.image(
            for: urls[0],
            maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
        )
        await expectCachedImages(pipeline, boxArt: 3, heroArt: 1)

        await pipeline.handleMemoryEvent(.streamOpening)
        await expectCachedImages(pipeline, boxArt: 3, heroArt: 1)

        await pipeline.handleMemoryEvent(.streaming)
        await expectCachedImages(pipeline, boxArt: 3, heroArt: 0)

        await pipeline.handleMemoryEvent(.foreground)
        _ = try await pipeline.image(
            for: urls[1],
            maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
        )
        await expectCachedImages(pipeline, boxArt: 3, heroArt: 1)

        await pipeline.handleMemoryEvent(.background)
        await expectCachedImages(pipeline, boxArt: 1, heroArt: 0)

        await pipeline.handleMemoryEvent(.foreground)
        _ = try await pipeline.image(
            for: urls[2],
            maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
        )
        #expect(await loader.requestedURLs().count == 5)
        _ = try await pipeline.image(
            for: urls[0],
            maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
        )
        #expect(await loader.requestedURLs().count == 6)

        await pipeline.handleMemoryEvent(.memoryWarning)
        await expectCachedImages(pipeline, boxArt: 0, heroArt: 0)
        _ = try await pipeline.image(
            for: urls[1],
            maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
        )
        await expectCachedImages(pipeline, boxArt: 1, heroArt: 0)
        #expect(await loader.requestedURLs().count == 7)
    }

    @Test("Stream opening cancels box art while allowing hero art to finish")
    func streamOpeningCancelsBoxArtOnly() async throws {
        let image = try makeImage(width: 2, height: 2)
        let loader = GatedArtworkLoader(image: image)
        let pipeline = makePipeline(loader: loader)
        let urls = try testURLs()
        let boxArt = Task {
            try await pipeline.image(
                for: urls[0],
                maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
            )
        }
        let heroArt = Task {
            try await pipeline.image(
                for: urls[1],
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
        }
        await loader.waitForCallCount(2)

        await pipeline.handleMemoryEvent(.streamOpening)
        let boxSnapshot = await pipeline.snapshot(
            maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
        )
        let heroSnapshot = await pipeline.snapshot(
            maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
        )
        #expect(boxSnapshot.inFlightRequestCount == 0)
        #expect(boxSnapshot.waiterCount == 0)
        #expect(heroSnapshot.inFlightRequestCount == 1)
        #expect(heroSnapshot.waiterCount == 1)

        await #expect(throws: CancellationError.self) {
            _ = try await pipeline.image(
                for: urls[2],
                maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
            )
        }
        #expect(await loader.callCount() == 2)
        let admittedHeroArt = Task {
            try await pipeline.image(
                for: urls[2],
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
        }
        await loader.waitForCallCount(3)

        await loader.releaseAll()
        await #expect(throws: CancellationError.self) {
            _ = try await boxArt.value
        }
        _ = try await heroArt.value
        _ = try await admittedHeroArt.value
        await expectCachedImages(pipeline, boxArt: 0, heroArt: 2)
    }

    @Test(
        "Suspended lifecycle events cancel in-flight artwork and reject new loads",
        arguments: SuspendedArtworkEvent.allCases
    )
    func suspendedEventsCancelAndReject(
        _ event: SuspendedArtworkEvent
    ) async throws {
        let image = try makeImage(width: 2, height: 2)
        let loader = GatedArtworkLoader(image: image)
        let pipeline = makePipeline(loader: loader)
        let urls = try testURLs()
        let boxArt = Task {
            try await pipeline.image(
                for: urls[0],
                maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
            )
        }
        let heroArt = Task {
            try await pipeline.image(
                for: urls[1],
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
        }
        await loader.waitForCallCount(2)

        await event.apply(to: pipeline)
        await loader.releaseAll()
        await #expect(throws: CancellationError.self) {
            _ = try await boxArt.value
        }
        await #expect(throws: CancellationError.self) {
            _ = try await heroArt.value
        }
        await expectCachedImages(pipeline, boxArt: 0, heroArt: 0)

        await #expect(throws: CancellationError.self) {
            _ = try await pipeline.image(
                for: urls[0],
                maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await pipeline.image(
                for: urls[1],
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
        }
        #expect(await loader.callCount() == 2)
    }

    @Test("A memory warning cancels work but permits a later recovery")
    func memoryWarningRecovery() async throws {
        let image = try makeImage(width: 2, height: 2)
        let loader = GatedArtworkLoader(image: image)
        let pipeline = makePipeline(loader: loader)
        let urls = try testURLs()
        let boxArt = Task {
            try await pipeline.image(
                for: urls[0],
                maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
            )
        }
        let heroArt = Task {
            try await pipeline.image(
                for: urls[1],
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
        }
        await loader.waitForCallCount(2)

        await pipeline.handleMemoryEvent(.memoryWarning)
        await loader.releaseAll()
        await #expect(throws: CancellationError.self) {
            _ = try await boxArt.value
        }
        await #expect(throws: CancellationError.self) {
            _ = try await heroArt.value
        }

        let replacementBoxArt = Task {
            try await pipeline.image(
                for: urls[0],
                maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
            )
        }
        let replacementHeroArt = Task {
            try await pipeline.image(
                for: urls[1],
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
        }
        await loader.waitForCallCount(4)
        await loader.releaseAll()
        _ = try await replacementBoxArt.value
        _ = try await replacementHeroArt.value
        await expectCachedImages(pipeline, boxArt: 1, heroArt: 1)
    }

    @Test("Clear cache evicts decoded images and cancels every pending load")
    func clearCacheIsCompleteBarrier() async throws {
        let image = try makeImage(width: 2, height: 2)
        let loader = GatedArtworkLoader(image: image)
        let pipeline = makePipeline(loader: loader)
        let urls = try testURLs()
        let cachedBoxArt = Task {
            try await pipeline.image(
                for: urls[0],
                maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
            )
        }
        let cachedHeroArt = Task {
            try await pipeline.image(
                for: urls[0],
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
        }
        await loader.waitForCallCount(2)
        await loader.releaseAll()
        _ = try await cachedBoxArt.value
        _ = try await cachedHeroArt.value
        await expectCachedImages(pipeline, boxArt: 1, heroArt: 1)

        let pendingBoxArt = Task {
            try await pipeline.image(
                for: urls[1],
                maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
            )
        }
        let pendingHeroArt = Task {
            try await pipeline.image(
                for: urls[1],
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
        }
        await loader.waitForCallCount(4)

        await pipeline.clearCache()
        await expectCachedImages(pipeline, boxArt: 0, heroArt: 0)
        await loader.releaseAll()
        await #expect(throws: CancellationError.self) {
            _ = try await pendingBoxArt.value
        }
        await #expect(throws: CancellationError.self) {
            _ = try await pendingHeroArt.value
        }

        let replacementBoxArt = Task {
            try await pipeline.image(
                for: urls[1],
                maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
            )
        }
        let replacementHeroArt = Task {
            try await pipeline.image(
                for: urls[1],
                maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
            )
        }
        await loader.waitForCallCount(6)
        await loader.releaseAll()
        _ = try await replacementBoxArt.value
        _ = try await replacementHeroArt.value
        await expectCachedImages(pipeline, boxArt: 1, heroArt: 1)

        await pipeline.handleMemoryEvent(.background)
        await pipeline.clearCache()
        await #expect(throws: CancellationError.self) {
            _ = try await pipeline.image(
                for: urls[2],
                maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
            )
        }
        #expect(await loader.callCount() == 6)
    }

    private func makePipeline(
        loader: RecordingArtworkLoader,
        budget: ArtworkImagePipeline.CacheBudget? = nil,
        backgroundBudget: ArtworkImagePipeline.CacheBudget? = nil,
        heroBudget: ArtworkImagePipeline.CacheBudget? = nil
    ) -> ArtworkImagePipeline {
        ArtworkImagePipeline(
            imageLoader: { url, maxPixelSize in
                try await loader.load(url: url, maxPixelSize: maxPixelSize)
            },
            foregroundBoxArtBudget: budget,
            backgroundBoxArtBudget: backgroundBudget,
            heroArtBudget: heroBudget
        )
    }

    private func makePipeline(loader: GatedArtworkLoader) -> ArtworkImagePipeline {
        ArtworkImagePipeline(
            imageLoader: { url, maxPixelSize in
                try await loader.load(url: url, maxPixelSize: maxPixelSize)
            }
        )
    }

    private func testURLs() throws -> [URL] {
        try [
            #require(URL(string: "https://example.invalid/a")),
            #require(URL(string: "https://example.invalid/b")),
            #require(URL(string: "https://example.invalid/c")),
        ]
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let bytesPerRow = width * 4
        let data = Data(repeating: 0x7F, count: bytesPerRow * height)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func waitForWaiterCount(
        _ expectedCount: Int,
        pipeline: ArtworkImagePipeline,
        maxPixelSize: Int
    ) async -> Bool {
        for _ in 0 ..< 1000 {
            if await pipeline.snapshot(maxPixelSize: maxPixelSize).waiterCount == expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func expectCachedImages(
        _ pipeline: ArtworkImagePipeline,
        boxArt expectedBoxArt: Int,
        heroArt expectedHeroArt: Int
    ) async {
        let boxArt = await pipeline.snapshot(
            maxPixelSize: ArtworkImagePipeline.boxArtPixelSize
        )
        let heroArt = await pipeline.snapshot(
            maxPixelSize: ArtworkImagePipeline.heroArtPixelSize
        )
        #expect(boxArt.cachedImageCount == expectedBoxArt)
        #expect(heroArt.cachedImageCount == expectedHeroArt)
        #expect(boxArt.inFlightRequestCount == 0)
        #expect(heroArt.inFlightRequestCount == 0)
    }
}

private enum ArtworkLoaderTestError: Error {
    case failed
}

private actor RecordingArtworkLoader {
    private let image: CGImage
    private var failuresRemaining: Int
    private var requests: [URL] = []

    init(image: CGImage, failuresRemaining: Int = 0) {
        self.image = image
        self.failuresRemaining = failuresRemaining
    }

    func load(url: URL, maxPixelSize _: Int) throws -> CGImage {
        requests.append(url)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw ArtworkLoaderTestError.failed
        }
        return image
    }

    func requestedURLs() -> [URL] {
        requests
    }
}

private actor GatedArtworkLoader {
    private let image: CGImage
    private var calls = 0
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(image: CGImage) {
        self.image = image
    }

    func load(url _: URL, maxPixelSize _: Int) async throws -> CGImage {
        calls += 1
        let ready = callWaiters.filter { $0.count <= calls }
        callWaiters.removeAll { $0.count <= calls }
        ready.forEach { $0.continuation.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
        try Task.checkCancellation()
        return image
    }

    func waitForCallCount(_ count: Int) async {
        guard calls < count else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((count, continuation))
        }
    }

    func releaseAll() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll(keepingCapacity: true)
        continuations.forEach { $0.resume() }
    }

    func callCount() -> Int {
        calls
    }
}
