import CoreLocation
import Foundation

/// Groups Transitland stop records that refer to the same physical boarding
/// place. Exact coordinate duplicates are always merged; differently named
/// cross-agency records are merged only when their normalized place names and
/// direction qualifiers agree. Pure and side-effect free.
enum StopClustering {

    /// Transitland's duplicate records for one pole can differ by a meter or
    /// two. Five feet is the strict rule for exact coordinate duplicates.
    static let duplicateStopDistanceMeters: Double = 1.524 // 5 feet

    /// Cross-agency stop coordinates can differ slightly even when they mark
    /// the same pole. Name matching keeps this deliberately small radius
    /// conservative.
    static let samePlaceStopDistanceMeters: Double = 15

    /// Splits a half-mile candidate set into logical boarding places. The
    /// candidate set is capped at 1,000 stops, making this pairwise pass
    /// inexpensive.
    static func cluster(stops: [TransitStop]) -> [[TransitStop]] {
        guard !stops.isEmpty else { return [] }

        let locations = stops.map {
            CLLocation(
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude
            )
        }
        var parents = Array(stops.indices)
        var clusterAgencyNames = stops.map { stop in
            Set(stop.agencyNames.map { TransitText.normalizedAgencyName($0) })
        }

        func root(of index: Int) -> Int {
            var current = index
            while parents[current] != current {
                current = parents[current]
            }
            return current
        }

        // Exact coordinate duplicates use the strict five-foot rule. A second,
        // conservative rule joins differently named agency records only when
        // their normalized place names and directions agree.
        for first in stops.indices {
            for second in stops.indices where second > first {
                let distance = locations[first].distance(from: locations[second])
                let isCoordinateDuplicate = distance <= duplicateStopDistanceMeters
                let isSameNamedPlace = distance <= samePlaceStopDistanceMeters
                    && representsSameNamedPlace(stops[first], stops[second])
                guard isCoordinateDuplicate || isSameNamedPlace else { continue }

                let firstRoot = root(of: first)
                let secondRoot = root(of: second)
                guard firstRoot != secondRoot else { continue }

                // A same-place cluster may contain only one record from a given
                // operator. This prevents transitive merging of two directional
                // platforms through a third agency's record.
                if !isCoordinateDuplicate,
                   !clusterAgencyNames[firstRoot].isDisjoint(
                       with: clusterAgencyNames[secondRoot]
                   ) {
                    continue
                }

                parents[secondRoot] = firstRoot
                clusterAgencyNames[firstRoot].formUnion(
                    clusterAgencyNames[secondRoot]
                )
            }
        }

        var grouped: [Int: [TransitStop]] = [:]
        for index in stops.indices {
            grouped[root(of: index), default: []].append(stops[index])
        }
        return grouped.keys.sorted().compactMap { grouped[$0] }
    }

    /// Cross-agency records for the same physical pole usually disagree on
    /// name formatting. Merge only when the place tokens and the direction
    /// qualifiers both agree — and only across different operators, since
    /// same-operator duplicates are handled by the coordinate rule.
    static func representsSameNamedPlace(
        _ first: TransitStop,
        _ second: TransitStop
    ) -> Bool {
        let firstAgencies = Set(first.agencyNames.map { TransitText.normalizedAgencyName($0) })
        let secondAgencies = Set(second.agencyNames.map { TransitText.normalizedAgencyName($0) })
        guard !firstAgencies.isEmpty,
              !secondAgencies.isEmpty,
              firstAgencies.isDisjoint(with: secondAgencies)
        else { return false }

        let firstName = TransitText.normalizedStopPlaceName(first.name)
        let secondName = TransitText.normalizedStopPlaceName(second.name)
        return !firstName.isEmpty
            && firstName == secondName
            && TransitText.stopDirectionTerms(in: first.name)
                == TransitText.stopDirectionTerms(in: second.name)
    }
}
