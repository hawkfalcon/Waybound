import Foundation

/// Shared identity-text folding used by stop clustering, route identity, and
/// journey deduplication. Kept as one pure namespace so every comparison in
/// the app uses the same rules — and so unit tests can pin those rules
/// without a live API key.
enum TransitText {

    /// Case- and diacritic-insensitive letter/digit skeleton of a value.
    /// "MTD (Santa Barbara)" and "mtd — santa barbara" fold identically.
    static func normalizedIdentityText(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
    }

    static func normalizedAgencyName(_ name: String) -> String {
        normalizedIdentityText(name)
    }

    /// Stop name reduced to its place tokens: landmark qualifiers in
    /// parentheses are dropped and connector words removed, so
    /// "State at Anapamu (SB Library)" and "State and Anapamu" compare equal.
    static func normalizedStopPlaceName(_ name: String) -> String {
        let landmarkFreeName = name.components(separatedBy: "(").first ?? name
        let foldedName = landmarkFreeName.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        let connectorWords: Set<String> = ["at", "and", "near"]
        return foldedName
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !connectorWords.contains($0) }
            .joined(separator: " ")
    }

    /// Direction qualifiers present in a stop name. Two-letter forms are
    /// deliberately not treated as directions: "SB" often means Santa Barbara,
    /// as in the landmark qualifier "(SB Library)".
    static func stopDirectionTerms(in name: String) -> Set<String> {
        let directionWords: Set<String> = [
            "northbound", "southbound", "eastbound", "westbound",
            "inbound", "outbound",
        ]
        let foldedName = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        return Set(
            foldedName
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { directionWords.contains($0) }
        )
    }
}
