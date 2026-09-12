import Foundation

#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(MapKit)
import MapKit
#endif

/// The Web Mercator projection MKMapPoint, the app's lane math, and the
/// replay harness all share. Keeping it here makes the projection and its
/// meter scales pure, platform-free, and pinnable with unit tests.
public enum GeoProjection {
    /// The Mercator world edge in projected units: 2^28, MKMapPoint's world.
    public static let worldSize: Double = 268_435_456

    /// WGS84 semi-major axis, metres.
    public static let earthSemiMajorAxis: Double = 6_378_137

    /// Meters per unit of projected x/y difference at `latitude`.
    ///
    /// Web Mercator is conformal: near a latitude, this single scale
    /// converts projected-unit distances to ground meters in every
    /// direction, so travelled distances and lateral projections can
    /// share one truth. The shipped app learned this the hard way —
    /// `MKMapPoint.distance()` and sums of coordinate deltas need
    /// different scales on the meter-based MapKit world of the Xcode 26
    /// SDKs, and mixing them silently overcounted every lateral read by
    /// 1/cos(latitude) (~21% in Santa Barbara). Code in this package
    /// converts everything through this scale instead.
    public static func metersPerUnit(atLatitude latitude: Double) -> Double {
        let radians = latitude * .pi / 180
        return cos(radians) * 2 * .pi * earthSemiMajorAxis / worldSize
    }
}

/// A latitude/longitude pair. Pure value; bridges to `CLLocationCoordinate2D`
/// on Apple platforms.
public struct GeoCoordinate: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Web Mercator projection into MKMapPoint's coordinate space.
    public var projected: ProjectedPoint {
        let x = (longitude + 180.0) / 360.0 * GeoProjection.worldSize
        let s = sin(latitude * .pi / 180.0)
        let y = (0.5 - log((1 + s) / (1 - s)) / (4 * .pi))
            * GeoProjection.worldSize
        return ProjectedPoint(x: x, y: y)
    }

    /// Inverse of `projected`.
    public static func fromProjected(_ point: ProjectedPoint) -> GeoCoordinate {
        let longitude = point.x / GeoProjection.worldSize * 360.0 - 180.0
        let latitude = 2 * atan(
            exp((0.5 - point.y / GeoProjection.worldSize) * 2 * .pi)
        ) * 180.0 / .pi - 90.0
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    #if canImport(CoreLocation)
    public init(_ coordinate: CLLocationCoordinate2D) {
        self.init(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    public var cl: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    #endif
}

/// A point in the shared Web Mercator space. Pure value; bridges to
/// `MKMapPoint` on Apple platforms.
public struct ProjectedPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: ProjectedPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }

    /// Ground meters between the two points, using the conformal scale at
    /// `latitude`. Accurate to well under 1% for the tens-of-metres spans
    /// lane math works over.
    public func meters(to other: ProjectedPoint, atLatitude latitude: Double)
        -> Double
    {
        distance(to: other) * GeoProjection.metersPerUnit(atLatitude: latitude)
    }

    #if canImport(MapKit)
    public init(_ point: MKMapPoint) {
        self.init(x: point.x, y: point.y)
    }

    public var mapPoint: MKMapPoint {
        MKMapPoint(x: x, y: y)
    }
    #endif
}
