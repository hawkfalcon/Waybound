# Waybound

An iOS map of real buses you can catch nearby. Waybound reads live and scheduled trips from [Transitland](https://www.transit.land), draws actual trip shapes on the street, and ranks boardable journeys by how soon they leave, how far you walk, and how often they come back.

The current focus is Santa Barbara / UCSB / Lompoc MTD service. The logic is feed-driven rather than a hardcoded destination list, so the same pipeline works anywhere Transitland has GTFS.

## Setup

1. Copy the example secrets file and add a Transitland REST API key from [transit.land](https://www.transit.land):

   ```sh
   cp Secrets.example.plist Waybound/Secrets.plist
   ```

   `Secrets.plist` is gitignored. Open it and set `TRANSITLAND_API_KEY`.

2. Open `Waybound.xcodeproj` in Xcode 26 and run the **Waybound** scheme.

A missing key no longer crashes the app. You get an alert asking you to add the key and relaunch.

## Architecture

Swift sources are grouped under `Waybound/` so the Xcode synchronized folder matches the layers:

```
Waybound/
  WayboundApp.swift          app entry
  Config.swift               Secrets.plist
  Models/                    stops, routes, journeys, GTFS decode
  Transit/                   fetch, score, cluster, draw-ready geometry
  Views/                     sheet chrome + MKMapView representable
```

- `Transit/TransitViewModel` owns location, Transitland fetching, and published map/sheet state.
- Pure decision rules in `Transit/` can be unit-tested without a network:
  - `TransitText` — identity folding for agencies, routes, and stop names
  - `StopClustering` — same-place merge of operator records
  - `TripPathGeometry` — spike cleanup, jump splits, radius clips, stop-to-shape alignment
  - `FlagshipSelection` — which downstream stop the journey is actually *for*
  - `RouteIdentity` — stable public route key and fallback color
  - `JourneyScoring` — overview ranking and duplicate-journey detection
  - `TransitHTTP` — concurrency cap (8 in-flight) and one retry with backoff
- `Views/WayboundMapView` is an `MKMapView` representable: screen-space corridor lanes, clustered route pills, destination callouts.
- `Views/ContentView` is the cream/ink sheet chrome on top of the map.

## Tests

The `WayboundTests` target hosts the app and exercises the pure logic above. In Xcode: **Product → Test** (⌘U).

## Deployment target

The project still ships with `IPHONEOS_DEPLOYMENT_TARGET = 26.2` (unchanged).

Without rewriting any call sites, the earliest OS the source can run on is **iOS 17.0**. The floor is set by three iOS 17 APIs:

- two-parameter `.onChange(of:) { _, value in … }`
- `Animation.snappy`
- `ContentUnavailableView`

There are no iOS 18+ APIs in the source. Building still needs the Xcode 26 toolchain (`objectVersion = 77` file-system-synchronized groups, `@retroactive Equatable`).
