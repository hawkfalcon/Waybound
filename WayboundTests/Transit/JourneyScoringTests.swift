import CoreLocation
import XCTest
@testable import Waybound

final class JourneyScoringTests: XCTestCase {

    func testUtilityScorePrefersAFrequentWalkableBusOverAnEarlierFartherOne() {
        let earlierWalk = TestFixtures.makeJourney(
            tripID: 1,
            departureMinutesFromNow: 10,
            walkMinutes: 5,
            observedDepartureCount: 1
        )
        let laterFrequent = TestFixtures.makeJourney(
            tripID: 2,
            departureMinutesFromNow: 20,
            walkMinutes: 0,
            observedDepartureCount: 3
        )
        XCTAssertEqual(JourneyScoring.utilityScore(earlierWalk, observedDepartureCount: 1), 35)
        XCTAssertEqual(JourneyScoring.utilityScore(laterFrequent, observedDepartureCount: 3), 24)
        XCTAssertTrue(
            JourneyScoring.ranksAhead(
                laterFrequent,
                of: earlierWalk,
                observedDepartureCounts: [1: 1, 2: 3],
                origin: CLLocation(
                    latitude: TestFixtures.baseLatitude,
                    longitude: TestFixtures.baseLongitude
                )
            )
        )
    }

    func testFrequencyBonusCapsAtEighteenMinutes() {
        let journey = TestFixtures.makeJourney(
            tripID: 1,
            departureMinutesFromNow: 0,
            walkMinutes: 0
        )
        let uncapped = JourneyScoring.utilityScore(journey, observedDepartureCount: 1)
        let capped = JourneyScoring.utilityScore(journey, observedDepartureCount: 100)
        XCTAssertEqual(uncapped - capped, JourneyScoring.maximumFrequencyBonusMinutes * 2)
        XCTAssertEqual(JourneyScoring.maximumFrequencyBonusMinutes, 18)
    }

    func testOrthogonalTravelVectorsAreNotTheSamePublicJourney() {
        let east = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 400),
        ]
        let north = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 400, east: 0),
        ]
        let first = TestFixtures.makeJourney(
            tripID: 1,
            directionID: nil,
            flagshipPolylines: [east]
        )
        let second = TestFixtures.makeJourney(
            tripID: 2,
            directionID: nil,
            flagshipPolylines: [north]
        )
        XCTAssertFalse(
            JourneyScoring.representsSamePublicJourney(first, second)
        )
    }

    func testParallelJourneysWithCloseEndpointsAreTheSamePublicJourney() {
        let east = [
            TestFixtures.coordinate(north: 0, east: 0),
            TestFixtures.coordinate(north: 0, east: 400),
        ]
        let first = TestFixtures.makeJourney(
            tripID: 1,
            directionID: nil,
            boarding: TestFixtures.coordinate(north: 0, east: 0),
            destination: TestFixtures.coordinate(north: 0, east: 400),
            flagshipPolylines: [east]
        )
        let second = TestFixtures.makeJourney(
            tripID: 2,
            directionID: nil,
            boarding: TestFixtures.coordinate(north: 0, east: 5),
            destination: TestFixtures.coordinate(north: 0, east: 410),
            flagshipPolylines: [east]
        )
        XCTAssertTrue(
            JourneyScoring.representsSamePublicJourney(first, second)
        )
    }

    func testDuplicateMergingUsesMeterThresholds() {
        // Platforms 120 m apart with flagship stops 800 m apart are still one
        // rider-facing journey at the documented 200 m / 2 km gates. The old
        // map-point comparison read those distances ~8x larger and kept both
        // records, drawing the same route twice with different shapes.
        let first = TestFixtures.makeJourney(
            tripID: 1,
            directionID: nil,
            boarding: TestFixtures.coordinate(north: 0, east: 0),
            destination: TestFixtures.coordinate(north: 0, east: 1_000),
            flagshipPolylines: [[
                TestFixtures.coordinate(north: 0, east: 0),
                TestFixtures.coordinate(north: 0, east: 1_000),
            ]]
        )
        let second = TestFixtures.makeJourney(
            tripID: 2,
            directionID: nil,
            boarding: TestFixtures.coordinate(north: 120, east: 0),
            destination: TestFixtures.coordinate(north: 0, east: 1_800),
            flagshipPolylines: [[
                TestFixtures.coordinate(north: 120, east: 0),
                TestFixtures.coordinate(north: 0, east: 1_800),
            ]]
        )
        XCTAssertTrue(
            JourneyScoring.representsSamePublicJourney(first, second)
        )
    }
}
