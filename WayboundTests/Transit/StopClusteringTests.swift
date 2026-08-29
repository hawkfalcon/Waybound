import XCTest
@testable import Waybound

final class StopClusteringTests: XCTestCase {

    func testIdenticalCoordinatesMergeEvenAcrossTheSameAgency() {
        let first = TestFixtures.makeStop(
            id: 1,
            name: "State & Anapamu",
            agencies: ["MTD"]
        )
        let second = TestFixtures.makeStop(
            id: 2,
            name: "State & Anapamu",
            agencies: ["MTD"],
            north: 1
        )
        let clusters = StopClustering.cluster(stops: [first, second])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0].map(\.id)), [1, 2])
    }

    func testCrossAgencySamePlaceMergesAndTreatsSBAsLandmarkNotDirection() {
        let mtd = TestFixtures.makeStop(
            id: 1,
            name: "State at Anapamu (SB Library)",
            agencies: ["MTD"]
        )
        let ucsb = TestFixtures.makeStop(
            id: 2,
            name: "State and Anapamu",
            agencies: ["UCSB"],
            east: 10
        )
        let clusters = StopClustering.cluster(stops: [mtd, ucsb])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0].map(\.id)), [1, 2])
    }

    func testOppositeDirectionsDoNotMerge() {
        let north = TestFixtures.makeStop(
            id: 1,
            name: "State & Anapamu Northbound",
            agencies: ["MTD"]
        )
        let south = TestFixtures.makeStop(
            id: 2,
            name: "State & Anapamu Southbound",
            agencies: ["UCSB"],
            east: 10
        )
        let clusters = StopClustering.cluster(stops: [north, south])
        XCTAssertEqual(clusters.count, 2)
    }

    func testSameAgencyDoesNotTransitivelyMergeThroughAnotherOperator() {
        // A (MTD) —12 m— B (UCSB) —12 m— C (MTD), all the same place name.
        // A∪B is allowed; C is blocked because the cluster already holds MTD.
        let a = TestFixtures.makeStop(
            id: 1,
            name: "State and Anapamu",
            agencies: ["MTD"]
        )
        let b = TestFixtures.makeStop(
            id: 2,
            name: "State and Anapamu",
            agencies: ["UCSB"],
            east: 12
        )
        let c = TestFixtures.makeStop(
            id: 3,
            name: "State and Anapamu",
            agencies: ["MTD"],
            east: 24
        )
        let clusters = StopClustering.cluster(stops: [a, b, c])
        let grouped = Set(clusters.map { Set($0.map(\.id)) })
        XCTAssertEqual(grouped.count, 2)
        XCTAssertTrue(grouped.contains([1, 2]))
        XCTAssertTrue(grouped.contains([3]))
    }

    func testDifferentPlaceNamesDoNotMergeAtSamePlaceRadius() {
        let first = TestFixtures.makeStop(
            id: 1,
            name: "State and Anapamu",
            agencies: ["MTD"]
        )
        let second = TestFixtures.makeStop(
            id: 2,
            name: "Chapala and Carrillo",
            agencies: ["UCSB"],
            east: 10
        )
        let clusters = StopClustering.cluster(stops: [first, second])
        XCTAssertEqual(clusters.count, 2)
    }

    func testNormalizedPlaceNameIsWordOrderSensitive() {
        let first = TestFixtures.makeStop(
            id: 1,
            name: "State and Anapamu",
            agencies: ["MTD"]
        )
        let second = TestFixtures.makeStop(
            id: 2,
            name: "Anapamu and State",
            agencies: ["UCSB"],
            east: 10
        )
        XCTAssertNotEqual(
            TransitText.normalizedStopPlaceName(first.name),
            TransitText.normalizedStopPlaceName(second.name)
        )
        XCTAssertEqual(StopClustering.cluster(stops: [first, second]).count, 2)
    }
}
