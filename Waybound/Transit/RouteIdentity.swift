import Foundation
import SwiftUI

/// Typed rider-facing identity keeps discovery, deduplication, and the final
/// route budget from quietly using different string formats for the same
/// route.
struct PublicRouteIdentity: Hashable {
    let agency: String
    let routeNumber: String

    var isUsable: Bool { !routeNumber.isEmpty }
    var stableText: String { "\(agency)|\(routeNumber)" }
}

enum RouteIdentity {

    static func identity(for route: TransitRoute) -> PublicRouteIdentity {
        PublicRouteIdentity(
            agency: TransitText.normalizedAgencyName(route.agencyName),
            routeNumber: TransitText.normalizedIdentityText(route.routeNumber ?? "")
        )
    }

    /// Deterministic fallback hue for routes whose operator publishes no GTFS
    /// color. The same public route (agency + number) always gets the same
    /// strand color, independent of fetch order or source record.
    static func stableColor(for route: TransitRoute) -> Color {
        let publicIdentity = identity(for: route)
        var hash: UInt64 = 1_469_598_103_934_665_603
        for scalar in publicIdentity.stableText.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 1_099_511_628_211
        }
        return WayboundPalette.routeColor(
            at: Int(hash % UInt64(WayboundPalette.routeColors.count))
        )
    }
}
