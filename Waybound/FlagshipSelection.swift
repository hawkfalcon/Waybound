import Foundation

/// Picks the "flagship" downstream stop for a journey: the place a rider is
/// actually boarding for, not merely the farthest stop in the GTFS file. The
/// scoring is semantic (headsign agreement, civic landmarks, terminus, ride
/// length), so it works wherever Transitland has stop data instead of a
/// hardcoded inventory of local places.
enum FlagshipSelection {

    static func selectIndex(
        in stops: [(stopTime: APITripStopTime, offset: Int)],
        headsign: String?,
        maximumRideMinutes: Int
    ) -> Int? {
        let landmarkTerms = [
            "airport", "beach", "campus", "center", "college", "courthouse",
            "downtown", "harbor", "hospital", "library", "mall", "museum",
            "park", "station", "terminal", "transit", "university",
        ]
        let headsignTerms = (headsign ?? "")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }
        let finalIndex = stops.count - 1
        let reachable = stops.indices.filter {
            stops[$0].offset > 0
                && stops[$0].offset <= maximumRideMinutes
        }
        guard !reachable.isEmpty else { return nil }

        // Prefer a substantial destination, but do not erase a legitimate
        // return direction merely because the rider is already near its
        // terminus. A short remaining trip can still answer where that side of
        // the line goes.
        let usefulDestinations = reachable.filter { stops[$0].offset >= 8 }
        let eligible = usefulDestinations.isEmpty ? reachable : usefulDestinations
        return eligible.max { lhs, rhs in
            func score(_ index: Int) -> Int {
                let item = stops[index]
                let name = (item.stopTime.stop.stopName ?? "")
                    .folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")
                    )
                    .lowercased()
                let matchedHeadsignTerms = headsignTerms.filter {
                    name.contains($0)
                }.count
                let headsignBonus: Int
                if !headsignTerms.isEmpty
                    && matchedHeadsignTerms == headsignTerms.count {
                    headsignBonus = 90 + matchedHeadsignTerms * 15
                } else if matchedHeadsignTerms > 0 {
                    headsignBonus = matchedHeadsignTerms * 45
                } else {
                    headsignBonus = 0
                }
                let landmarkBonus = landmarkTerms.contains {
                    name.contains($0)
                } ? 35 : 0
                let terminusBonus = index == finalIndex ? 45 : 0
                let usefulRideScore = max(0, 30 - abs(item.offset - 35))
                let progressScore = Int(
                    (Double(index) / Double(max(1, finalIndex))) * 20
                )
                let veryLongPenalty = max(0, item.offset - 120) / 2
                return headsignBonus + landmarkBonus + terminusBonus
                    + usefulRideScore + progressScore - veryLongPenalty
            }
            return score(lhs) < score(rhs)
        }
    }

    /// Direction-only headsigns ("Inbound", "Northbound") carry no destination
    /// information and are dropped before naming a journey.
    static func cleanedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic = ["inbound", "outbound", "northbound", "southbound"]
        guard !cleaned.isEmpty,
              !generic.contains(cleaned.lowercased())
        else { return nil }
        return cleaned
    }
}
