import XCTest
@testable import Waybound

final class FlagshipSelectionTests: XCTestCase {

    func testHeadsignMatchBeatsTerminus() {
        let stops = [
            makeStopTime(sequence: 1, name: "Oak & Main", offset: 5),
            makeStopTime(sequence: 2, name: "Community Hospital", offset: 20),
            makeStopTime(sequence: 3, name: "End of Line", offset: 40),
        ]
        XCTAssertEqual(
            FlagshipSelection.selectIndex(
                in: stops,
                headsign: "Community Hospital",
                maximumRideMinutes: 180
            ),
            1
        )
    }

    func testDirectionOnlyHeadsignFallsBackToTerminus() {
        let stops = [
            makeStopTime(sequence: 1, name: "Oak & Main", offset: 5),
            makeStopTime(sequence: 2, name: "Community Hospital", offset: 20),
            makeStopTime(sequence: 3, name: "End of Line", offset: 40),
        ]
        XCTAssertEqual(
            FlagshipSelection.selectIndex(
                in: stops,
                headsign: "Inbound",
                maximumRideMinutes: 180
            ),
            2
        )
    }

    func testShortRemainingTripStillPicksTheFartherStop() {
        let stops = [
            makeStopTime(sequence: 1, name: "A", offset: 5),
            makeStopTime(sequence: 2, name: "B", offset: 7),
        ]
        XCTAssertEqual(
            FlagshipSelection.selectIndex(
                in: stops,
                headsign: nil,
                maximumRideMinutes: 180
            ),
            1
        )
    }

    func testUnreachableOffsetsReturnNil() {
        let stops = [
            makeStopTime(sequence: 1, name: "A", offset: 0),
            makeStopTime(sequence: 2, name: "B", offset: 0),
        ]
        XCTAssertNil(
            FlagshipSelection.selectIndex(
                in: stops,
                headsign: nil,
                maximumRideMinutes: 180
            )
        )
    }

    func testCleanedNameDropsDirectionOnlyHeadsigns() {
        XCTAssertNil(FlagshipSelection.cleanedName("Inbound"))
        XCTAssertNil(FlagshipSelection.cleanedName("outbound"))
        XCTAssertNil(FlagshipSelection.cleanedName("Northbound"))
        XCTAssertNil(FlagshipSelection.cleanedName(nil))
        XCTAssertEqual(
            FlagshipSelection.cleanedName("Community Hospital"),
            "Community Hospital"
        )
    }

    private func makeStopTime(
        sequence: Int,
        name: String,
        offset: Int
    ) -> (stopTime: APITripStopTime, offset: Int) {
        let stop = APITripStop(
            id: sequence,
            stopName: name,
            geometry: GeoJSONPoint(type: "Point", coordinates: [0, 0])
        )
        let stopTime = APITripStopTime(
            arrivalTime: "08:00:00",
            departureTime: "08:00:00",
            stopSequence: sequence,
            stopHeadsign: nil,
            stop: stop
        )
        return (stopTime, offset)
    }
}
