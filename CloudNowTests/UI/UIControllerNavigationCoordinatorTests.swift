@testable import CloudNow
import Foundation
import Testing

@Suite("Controller navigation ownership")
struct UIControllerNavigationCoordinatorTests {
    @MainActor
    @Test("A late stop cannot clear a newer shell's controller ownership")
    func lateStopPreservesNewOwner() {
        let first = UIControllerNavigationCoordinator()
        let second = UIControllerNavigationCoordinator()

        first.start(onPreviousTab: {}, onNextTab: {})
        #expect(first.ownsGlobalControllerHandlers)

        second.start(onPreviousTab: {}, onNextTab: {})
        #expect(!first.ownsGlobalControllerHandlers)
        #expect(second.ownsGlobalControllerHandlers)

        first.stop()
        #expect(second.ownsGlobalControllerHandlers)

        second.stop()
        #expect(!second.ownsGlobalControllerHandlers)
    }

    @MainActor
    @Test("A modal context suspends and restores the previous navigation mode")
    func modalContextRestoresPreviousMode() {
        let coordinator = UIControllerNavigationCoordinator()
        let carouselContext = UUID()
        let modalContext = UUID()

        coordinator.activateContext(id: carouselContext, mode: .carousel)
        #expect(coordinator.activeMode == .carousel)

        coordinator.activateContext(id: modalContext, mode: .modal)
        #expect(coordinator.activeMode == .modal)

        coordinator.deactivateContext(id: modalContext)
        #expect(coordinator.activeMode == .carousel)

        coordinator.deactivateContext(id: carouselContext)
        #expect(coordinator.activeMode == .tabs)
    }
}

@Suite("Top-level controller navigation ring")
struct TopLevelNavigationRingTests {
    private typealias Destination = CloudNowTopLevelNavigationDestination<FixtureTab>

    @Test("Shoulders include the provider menu before the first and after the last tab")
    func destinationRing() {
        #expect(Destination.providerMenu.next == .tab(.home))
        #expect(Destination.tab(.home).previous == .providerMenu)
        #expect(Destination.tab(.home).next == .tab(.library))
        #expect(Destination.tab(.library).previous == .tab(.home))
        #expect(Destination.tab(.settings).next == .providerMenu)
        #expect(Destination.providerMenu.previous == .tab(.settings))
    }

    private enum FixtureTab: CloudNowTabSelection {
        case home
        case library
        case settings

        static let first = FixtureTab.home
        static let last = FixtureTab.settings

        var previous: FixtureTab {
            switch self {
            case .home:
                .settings
            case .library:
                .home
            case .settings:
                .library
            }
        }

        var next: FixtureTab {
            switch self {
            case .home:
                .library
            case .library:
                .settings
            case .settings:
                .home
            }
        }
    }
}
