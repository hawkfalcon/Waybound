import Foundation
import CoreLocation
import MapKit

// MARK: - Grid snapping (step 1)

struct CorridorGridNode: Hashable {
    let x: Int
    let y: Int
}

struct CorridorDirectedEdgeKey: Hashable {
    let from: CorridorGridNode
    let to: CorridorGridNode
}

// MARK: - Corridor graph (step 2)

struct CorridorEdge {
    let key: CorridorDirectedEdgeKey
    let fromPoint: MKMapPoint
    let toPoint: MKMapPoint
    var routeIDs: Set<Int> = []
    var orderedRouteIDs: [Int] = [] // representatives, one per publicKey
}

struct CorridorRoutePath {
    let routeID: Int
    var edgeKeys: [CorridorDirectedEdgeKey] = []
    var edgePositions: [CorridorDirectedEdgeKey: [Int]] = [:]
}

struct CorridorRouteInfo {
    let publicKey: String
    let agencyName: String
    let routeNumber: String
    let directionID: Int?
    let observedDepartureCount: Int
    let stackOrder: Int
}

struct CorridorGraph {
    var edges: [CorridorDirectedEdgeKey: CorridorEdge] = [:]
    var nodes: Set<CorridorGridNode> = []
    var nodePoints: [CorridorGridNode: MKMapPoint] = [:]
    // spatial index: quantized cell -> [node]
    var spatialIndex: [CorridorGridNode: [CorridorGridNode]] = [:]
    // edge spatial index: quantized cell of midpoint -> [edgeKey]
    var edgeSpatialIndex: [CorridorGridNode: [CorridorDirectedEdgeKey]] = [:]
    var routePaths: [Int: CorridorRoutePath] = [:]
    var routeInfo: [Int: CorridorRouteInfo] = [:]
    var feedVersionHash: String = ""
    var gridSizeMapPoints: Double = 0
}

// MARK: - Input abstraction

struct CorridorRouteInput {
    let id: Int
    let polylines: [[CLLocationCoordinate2D]]
    let publicKey: String
    let agencyName: String
    let routeNumber: String
    let directionID: Int?
    let observedDepartureCount: Int
    let stackOrder: Int

    // Convenience init for callers that don't have extra info (tests)
    init(id: Int, polylines: [[CLLocationCoordinate2D]]) {
        self.id = id
        self.polylines = polylines
        self.publicKey = "id:\(id)"
        self.agencyName = ""
        self.routeNumber = "\(id)"
        self.directionID = nil
        self.observedDepartureCount = 0
        self.stackOrder = id
    }

    init(id: Int, polylines: [[CLLocationCoordinate2D]], publicKey: String, agencyName: String, routeNumber: String, directionID: Int?, observedDepartureCount: Int, stackOrder: Int) {
        self.id = id
        self.polylines = polylines
        self.publicKey = publicKey
        self.agencyName = agencyName
        self.routeNumber = routeNumber
        self.directionID = directionID
        self.observedDepartureCount = observedDepartureCount
        self.stackOrder = stackOrder
    }
}

// MARK: - Builder

enum CorridorGraphBuilder {

    static let defaultGridSizeMeters: Double = 7.0
    static let densifyMeters: Double = 18.0

    static func metersPerMapPoint(atLatitude latitude: Double) -> Double {
        TripPathGeometry.metersPerMapPoint(atLatitude: latitude)
    }

    static func build(
        from inputs: [CorridorRouteInput],
        gridSizeMeters: Double = defaultGridSizeMeters,
        feedVersionHash: String = ""
    ) -> CorridorGraph {
        guard !inputs.isEmpty else { return CorridorGraph() }

        let referenceLatitude = inputs.first?.polylines.first?.first?.latitude ?? 34.42
        let mPerPoint = metersPerMapPoint(atLatitude: referenceLatitude)
        let gridSizeMapPoints = gridSizeMeters / mPerPoint
        let mergeToleranceMapPoints = gridSizeMapPoints * 1.4 // 9.8m for 7m grid

        var graph = CorridorGraph()
        graph.feedVersionHash = feedVersionHash
        graph.gridSizeMapPoints = gridSizeMapPoints

        // store route info
        for input in inputs {
            graph.routeInfo[input.id] = CorridorRouteInfo(
                publicKey: input.publicKey,
                agencyName: input.agencyName,
                routeNumber: input.routeNumber,
                directionID: input.directionID,
                observedDepartureCount: input.observedDepartureCount,
                stackOrder: input.stackOrder
            )
        }

        var nodePoints: [CorridorGridNode: MKMapPoint] = [:]
        var spatialIndex: [CorridorGridNode: [CorridorGridNode]] = [:]

        func quantizedNode(for point: MKMapPoint) -> CorridorGridNode {
            CorridorGridNode(
                x: Int((point.x / gridSizeMapPoints).rounded()),
                y: Int((point.y / gridSizeMapPoints).rounded())
            )
        }

        func findNearestNode(to point: MKMapPoint, near quantized: CorridorGridNode) -> CorridorGridNode? {
            var best: CorridorGridNode?
            var bestDist = Double.greatestFiniteMagnitude
            for dx in -1...1 {
                for dy in -1...1 {
                    let cell = CorridorGridNode(x: quantized.x + dx, y: quantized.y + dy)
                    guard let candidates = spatialIndex[cell] else { continue }
                    for cand in candidates {
                        guard let candPoint = nodePoints[cand] else { continue }
                        let d = point.distance(to: candPoint)
                        if d <= mergeToleranceMapPoints && d < bestDist {
                            bestDist = d
                            best = cand
                        }
                    }
                }
            }
            return best
        }

        func getOrCreateNode(for point: MKMapPoint) -> CorridorGridNode {
            let q = quantizedNode(for: point)
            if let nearest = findNearestNode(to: point, near: q) {
                return nearest
            }
            // No nearby node – create new. Ensure key uniqueness: if q already used but far, find free nearby key.
            var key = q
            if nodePoints[key] != nil {
                var found = false
                for r in 1...2 where !found {
                    for dx in -r...r {
                        for dy in -r...r where !found {
                            let cand = CorridorGridNode(x: q.x + dx, y: q.y + dy)
                            if nodePoints[cand] == nil {
                                key = cand
                                found = true
                            }
                        }
                    }
                }
            }
            nodePoints[key] = point
            spatialIndex[q, default: []].append(key)
            if key != q {
                spatialIndex[key, default: []].append(key)
            }
            return key
        }

        struct RouteDensified {
            let routeID: Int
            var segments: [(from: CorridorGridNode, to: CorridorGridNode, fromPoint: MKMapPoint, toPoint: MKMapPoint)] = []
        }

        var routesDensified: [RouteDensified] = []

        for input in inputs {
            var rd = RouteDensified(routeID: input.id)
            for polyline in input.polylines where polyline.count >= 2 {
                let densifiedCoords = densifiedCoordinates(polyline, maxSegmentMeters: densifyMeters, mPerPoint: mPerPoint)
                var localPoints: [MKMapPoint] = densifiedCoords.map { MKMapPoint($0) }
                var localNodes: [CorridorGridNode] = []
                localNodes.reserveCapacity(localPoints.count)
                for mp in localPoints {
                    localNodes.append(getOrCreateNode(for: mp))
                }
                var dedupNodes: [CorridorGridNode] = []
                var dedupPoints: [MKMapPoint] = []
                for (n, p) in zip(localNodes, localPoints) {
                    if dedupNodes.last != n {
                        dedupNodes.append(n)
                        dedupPoints.append(p)
                    }
                }
                for idx in 0..<(dedupNodes.count - 1) {
                    let fromNode = dedupNodes[idx]
                    let toNode = dedupNodes[idx + 1]
                    guard fromNode != toNode else { continue }
                    rd.segments.append((from: fromNode, to: toNode, fromPoint: dedupPoints[idx], toPoint: dedupPoints[idx+1]))
                }
            }
            routesDensified.append(rd)
        }

        for rd in routesDensified {
            var path = CorridorRoutePath(routeID: rd.routeID)
            var seen: [CorridorDirectedEdgeKey] = []
            seen.reserveCapacity(rd.segments.count)
            for seg in rd.segments {
                let key = CorridorDirectedEdgeKey(from: seg.from, to: seg.to)
                seen.append(key)
                if var existing = graph.edges[key] {
                    existing.routeIDs.insert(rd.routeID)
                    graph.edges[key] = existing
                } else {
                    let edge = CorridorEdge(
                        key: key,
                        fromPoint: seg.fromPoint,
                        toPoint: seg.toPoint,
                        routeIDs: [rd.routeID],
                        orderedRouteIDs: []
                    )
                    graph.edges[key] = edge
                }
                graph.nodes.insert(seg.from)
                graph.nodes.insert(seg.to)
            }
            path.edgeKeys = seen
            var posMap: [CorridorDirectedEdgeKey: [Int]] = [:]
            for (pos, key) in seen.enumerated() {
                posMap[key, default: []].append(pos)
            }
            path.edgePositions = posMap
            graph.routePaths[rd.routeID] = path
        }

        graph.nodePoints = nodePoints
        graph.spatialIndex = spatialIndex

        // Build edge spatial index for fast parallel corridor lookup
        var edgeSpatialIndex: [CorridorGridNode: [CorridorDirectedEdgeKey]] = [:]
        for (key, edge) in graph.edges {
            let mid = MKMapPoint(x: (edge.fromPoint.x + edge.toPoint.x)/2, y: (edge.fromPoint.y + edge.toPoint.y)/2)
            let q = CorridorGridNode(
                x: Int((mid.x / gridSizeMapPoints).rounded()),
                y: Int((mid.y / gridSizeMapPoints).rounded())
            )
            edgeSpatialIndex[q, default: []].append(key)
            // also add neighboring cells for tolerance
            for dx in -1...1 {
                for dy in -1...1 where !(dx==0 && dy==0) {
                    let nq = CorridorGridNode(x: q.x+dx, y: q.y+dy)
                    edgeSpatialIndex[nq, default: []].append(key)
                }
            }
        }
        graph.edgeSpatialIndex = edgeSpatialIndex

        // Compute global stable order of all routes (publicKey grouping) for consistent lane ordering
        let globalSortedRouteIDs = graph.routeInfo.keys.sorted { a, b in
            guard let infoA = graph.routeInfo[a], let infoB = graph.routeInfo[b] else { return a < b }
            if infoA.agencyName != infoB.agencyName { return infoA.agencyName < infoB.agencyName }
            let numA = Int(infoA.routeNumber.filter { $0.isNumber })
            let numB = Int(infoB.routeNumber.filter { $0.isNumber })
            if let na = numA, let nb = numB, na != nb { return na < nb }
            if infoA.routeNumber != infoB.routeNumber { return infoA.routeNumber < infoB.routeNumber }
            let dirA = infoA.directionID ?? Int.max
            let dirB = infoB.directionID ?? Int.max
            if dirA != dirB { return dirA < dirB }
            if infoA.observedDepartureCount != infoB.observedDepartureCount { return infoA.observedDepartureCount > infoB.observedDepartureCount }
            if infoA.stackOrder != infoB.stackOrder { return infoA.stackOrder < infoB.stackOrder }
            return a < b
        }
        var globalRank: [Int: Int] = [:]
        for (rank, rid) in globalSortedRouteIDs.enumerated() {
            globalRank[rid] = rank
        }
        // Also map publicKey to global rank of its best representative
        var publicKeyGlobalRank: [String: Int] = [:]
        for rid in globalSortedRouteIDs {
            guard let info = graph.routeInfo[rid] else { continue }
            if publicKeyGlobalRank[info.publicKey] == nil {
                publicKeyGlobalRank[info.publicKey] = globalRank[rid] ?? Int.max
            }
        }

        // Initialize ordering: deduplicate by publicKey per edge, then sort by global rank
        for (key, var edge) in graph.edges {
            let ordered = initialOrderedRepresentatives(for: edge, routeInfo: graph.routeInfo, globalRank: globalRank, publicKeyGlobalRank: publicKeyGlobalRank)
            edge.orderedRouteIDs = ordered
            graph.edges[key] = edge
        }

        return graph
    }

    // One representative per publicKey, sorted by global rank
    static func initialOrderedRepresentatives(for edge: CorridorEdge, routeInfo: [Int: CorridorRouteInfo], globalRank: [Int: Int], publicKeyGlobalRank: [String: Int]) -> [Int] {
        var bestPerKey: [String: Int] = [:]
        for rid in edge.routeIDs {
            guard let info = routeInfo[rid] else {
                bestPerKey["id:\(rid)"] = rid
                continue
            }
            let key = info.publicKey
            if let existing = bestPerKey[key] {
                guard let existingInfo = routeInfo[existing] else {
                    bestPerKey[key] = rid
                    continue
                }
                if info.observedDepartureCount != existingInfo.observedDepartureCount {
                    if info.observedDepartureCount > existingInfo.observedDepartureCount {
                        bestPerKey[key] = rid
                    }
                } else if info.stackOrder != existingInfo.stackOrder {
                    if info.stackOrder < existingInfo.stackOrder {
                        bestPerKey[key] = rid
                    }
                } else if rid < existing {
                    bestPerKey[key] = rid
                }
            } else {
                bestPerKey[key] = rid
            }
        }
        let representatives = Array(bestPerKey.values)
        return representatives.sorted { a, b in
            let rankA: Int
            let rankB: Int
            if let infoA = routeInfo[a], let pkRankA = publicKeyGlobalRank[infoA.publicKey] {
                rankA = pkRankA
            } else {
                rankA = globalRank[a] ?? Int.max
            }
            if let infoB = routeInfo[b], let pkRankB = publicKeyGlobalRank[infoB.publicKey] {
                rankB = pkRankB
            } else {
                rankB = globalRank[b] ?? Int.max
            }
            if rankA != rankB { return rankA < rankB }
            return a < b
        }
    }

    static func densifiedCoordinates(
        _ coords: [CLLocationCoordinate2D],
        maxSegmentMeters: Double,
        mPerPoint: Double
    ) -> [CLLocationCoordinate2D] {
        guard coords.count >= 2 else { return coords }
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(coords.count * 2)
        for i in 0..<(coords.count - 1) {
            let a = coords[i]
            let b = coords[i + 1]
            let aPoint = MKMapPoint(a)
            let bPoint = MKMapPoint(b)
            let distMeters = aPoint.distance(to: bPoint) * mPerPoint
            let steps = max(1, Int(ceil(distMeters / maxSegmentMeters)))
            if i == 0 {
                result.append(a)
            }
            for s in 1...steps {
                let t = Double(s) / Double(steps)
                let interp = MKMapPoint(
                    x: aPoint.x + (bPoint.x - aPoint.x) * t,
                    y: aPoint.y + (bPoint.y - aPoint.y) * t
                ).coordinate
                result.append(interp)
            }
        }
        return result
    }
}

// MARK: - Lane ordering (step 3) – barycenter / Sugiyama sweep

enum CorridorLaneOrdering {

    static func computeStableOrder(
        for graph: inout CorridorGraph,
        maxIterations: Int = 6
    ) {
        guard !graph.edges.isEmpty else { return }

        func rankMap(for graph: CorridorGraph) -> [CorridorDirectedEdgeKey: [Int: Int]] {
            var map: [CorridorDirectedEdgeKey: [Int: Int]] = [:]
            for (key, edge) in graph.edges {
                var r: [Int: Int] = [:]
                for (idx, rid) in edge.orderedRouteIDs.enumerated() {
                    r[rid] = idx
                }
                map[key] = r
            }
            return map
        }

        var currentRankMap = rankMap(for: graph)

        for _ in 0..<maxIterations {
            var changed = false
            let sortedEdgeKeys = graph.edges.keys.sorted { lhs, rhs in
                if lhs.from.x != rhs.from.x { return lhs.from.x < rhs.from.x }
                if lhs.from.y != rhs.from.y { return lhs.from.y < rhs.from.y }
                if lhs.to.x != rhs.to.x { return lhs.to.x < rhs.to.x }
                return lhs.to.y < rhs.to.y
            }

            var newOrderings: [CorridorDirectedEdgeKey: [Int]] = [:]

            for edgeKey in sortedEdgeKeys {
                guard let edge = graph.edges[edgeKey] else { continue }
                if edge.orderedRouteIDs.count <= 1 {
                    newOrderings[edgeKey] = edge.orderedRouteIDs
                    continue
                }

                var barycenters: [(routeID: Int, bary: Double)] = []

                for repID in edge.orderedRouteIDs {
                    let currentRank = Double(currentRankMap[edgeKey]?[repID] ?? 0)
                    guard let path = graph.routePaths[repID] else {
                        barycenters.append((repID, currentRank))
                        continue
                    }
                    let positions = path.edgePositions[edgeKey] ?? []
                    if positions.isEmpty {
                        barycenters.append((repID, currentRank))
                        continue
                    }
                    var neighborRanks: [Double] = []
                    for pos in positions {
                        if pos > 0 {
                            let prevKey = path.edgeKeys[pos - 1]
                            if let prevRank = currentRankMap[prevKey]?[repID] {
                                neighborRanks.append(Double(prevRank))
                            }
                        }
                        if pos + 1 < path.edgeKeys.count {
                            let nextKey = path.edgeKeys[pos + 1]
                            if let nextRank = currentRankMap[nextKey]?[repID] {
                                neighborRanks.append(Double(nextRank))
                            }
                        }
                    }
                    let neighborAvg: Double
                    if neighborRanks.isEmpty {
                        neighborAvg = currentRank
                    } else {
                        neighborAvg = neighborRanks.reduce(0, +) / Double(neighborRanks.count)
                    }
                    // Damping: 60% current, 40% neighbor average – prevents large jumps that cause swapping
                    let bary = currentRank * 0.6 + neighborAvg * 0.4
                    barycenters.append((repID, bary))
                }

                // Sort by barycenter, tie-break by global stable order to minimize crossings deterministically
                let sorted = barycenters.sorted { a, b in
                    if abs(a.bary - b.bary) > 0.001 {
                        return a.bary < b.bary
                    }
                    if let infoA = graph.routeInfo[a.routeID], let infoB = graph.routeInfo[b.routeID] {
                        if infoA.agencyName != infoB.agencyName { return infoA.agencyName < infoB.agencyName }
                        if infoA.routeNumber != infoB.routeNumber { return infoA.routeNumber < infoB.routeNumber }
                        if infoA.stackOrder != infoB.stackOrder { return infoA.stackOrder < infoB.stackOrder }
                    }
                    return a.routeID < b.routeID
                }.map { $0.routeID }

                if sorted != edge.orderedRouteIDs {
                    changed = true
                }
                newOrderings[edgeKey] = sorted
            }

            for (key, ordering) in newOrderings {
                graph.edges[key]?.orderedRouteIDs = ordering
            }
            currentRankMap = rankMap(for: graph)

            // After each iteration, stabilize long corridors to keep continuing routes from swapping
            stabilizeLongCorridors(graph: &graph)
            currentRankMap = rankMap(for: graph)

            if !changed { break }
        }

        stabilizeLongCorridors(graph: &graph)
    }

    private static func stabilizeLongCorridors(graph: inout CorridorGraph) {
        // For each route path, stabilize ordering across contiguous corridor.
        // Original code held lane for whole contiguous corridor and let joining routes take outside lane.
        for (routeID, path) in graph.routePaths {
            guard path.edgeKeys.count > 1 else { continue }
            var runStart = 0
            while runStart < path.edgeKeys.count {
                guard let firstEdge = graph.edges[path.edgeKeys[runStart]] else {
                    runStart += 1
                    continue
                }
                let firstOrder = firstEdge.orderedRouteIDs
                var runEnd = runStart + 1
                // Extend run while sets are compatible (identical or superset with same existing order)
                while runEnd < path.edgeKeys.count {
                    guard let nextEdge = graph.edges[path.edgeKeys[runEnd]] else { break }
                    // If next set is superset of first set, or identical, keep extending
                    // Check if all existing routes in firstOrder that are present in nextEdge keep same relative order
                    let nextOrder = nextEdge.orderedRouteIDs
                    // Quick check: firstOrder filtered to nextEdge's routes should equal nextOrder filtered to first's routes in same order
                    let firstFiltered = firstOrder.filter { rep in
                        nextEdge.routeIDs.contains(rep) || nextEdge.routeIDs.contains { rid in graph.routeInfo[rid]?.publicKey == graph.routeInfo[rep]?.publicKey }
                    }
                    let nextFiltered = nextOrder.filter { rep in
                        firstEdge.routeIDs.contains(rep) || firstEdge.routeIDs.contains { rid in graph.routeInfo[rid]?.publicKey == graph.routeInfo[rep]?.publicKey }
                    }
                    // If relative order of common routes is same, we can extend
                    if firstFiltered == nextFiltered {
                        runEnd += 1
                    } else if nextEdge.routeIDs == firstEdge.routeIDs {
                        // identical set but order differs – we will fix it
                        runEnd += 1
                    } else {
                        break
                    }
                }

                if runEnd - runStart > 1 {
                    let canonicalOrder = firstOrder
                    for idx in runStart..<runEnd {
                        let key = path.edgeKeys[idx]
                        guard var edge = graph.edges[key] else { continue }
                        // Reorder edge to match canonical order for common routes, new routes go to outside
                        // Preserve canonical order for routes that exist, then append new routes sorted by global order at outside
                        var newOrder: [Int] = []
                        // First, add routes from canonical that exist in this edge, in canonical order
                        for rep in canonicalOrder {
                            if edge.routeIDs.contains(rep) || edge.routeIDs.contains(where: { rid in graph.routeInfo[rid]?.publicKey == graph.routeInfo[rep]?.publicKey }) {
                                if !newOrder.contains(rep) {
                                    newOrder.append(rep)
                                }
                            }
                        }
                        // Then add remaining routes (joining) sorted by their global stable order, placed at outside edge
                        // Determine outside side: if canonical median is left, new routes go to right, etc. For simplicity, append at end (right side)
                        // But to mimic original entering from outside, we sort joining routes and append
                        let remaining = edge.orderedRouteIDs.filter { !newOrder.contains($0) }
                        // Sort remaining by global stable order (already sorted, but keep)
                        newOrder.append(contentsOf: remaining)
                        if newOrder.count == edge.orderedRouteIDs.count {
                            edge.orderedRouteIDs = newOrder
                            graph.edges[key] = edge
                        }
                    }
                }
                runStart = runEnd
            }
        }
    }
}

// MARK: - Rendering helper (step 4)

enum CorridorLaneRendering {

    static func laneOffset(rank: Int, totalLanes: Int, spacing: Double) -> Double {
        let median = Double(totalLanes - 1) / 2.0
        return (Double(rank) - median) * spacing
    }

    // Fast nearest node using graph's spatial index
    private static func nearestGraphNode(to point: MKMapPoint, graph: CorridorGraph, gridSizeMapPoints: Double, tolerance: Double) -> CorridorGridNode? {
        let q = CorridorGridNode(
            x: Int((point.x / gridSizeMapPoints).rounded()),
            y: Int((point.y / gridSizeMapPoints).rounded())
        )
        var best: CorridorGridNode?
        var bestDist = Double.greatestFiniteMagnitude
        for dx in -1...1 {
            for dy in -1...1 {
                let cell = CorridorGridNode(x: q.x + dx, y: q.y + dy)
                guard let candidates = graph.spatialIndex[cell] else { continue }
                for cand in candidates {
                    guard let candPoint = graph.nodePoints[cand] else { continue }
                    let d = point.distance(to: candPoint)
                    if d <= tolerance && d < bestDist {
                        bestDist = d
                        best = cand
                    }
                }
            }
        }
        return best
    }

    private static func findNearbySharedEdge(
        queryFrom: MKMapPoint,
        queryTo: MKMapPoint,
        routeID: Int,
        queryPublicKey: String?,
        graph: CorridorGraph,
        mPerPoint: Double,
        spacing: Double
    ) -> (Bool, Double)? {
        let mid = MKMapPoint(x: (queryFrom.x + queryTo.x)/2, y: (queryFrom.y + queryTo.y)/2)
        let gridSize = graph.gridSizeMapPoints > 0 ? graph.gridSizeMapPoints : 10
        let q = CorridorGridNode(
            x: Int((mid.x / gridSize).rounded()),
            y: Int((mid.y / gridSize).rounded())
        )
        let maxSeparationMeters: Double = 20
        let minParallelDot: Double = 0.93

        // query direction
        let qdx = queryTo.x - queryFrom.x
        let qdy = queryTo.y - queryFrom.y
        let qLen = hypot(qdx, qdy)
        guard qLen > 1e-9 else { return nil }
        let qUnitX = qdx / qLen
        let qUnitY = qdy / qLen

        var bestEdge: CorridorEdge?
        var bestDist = Double.greatestFiniteMagnitude

        // search 3x3 cells in edge index
        for dx in -1...1 {
            for dy in -1...1 {
                let cell = CorridorGridNode(x: q.x + dx, y: q.y + dy)
                guard let candidateKeys = graph.edgeSpatialIndex[cell] else { continue }
                for key in candidateKeys {
                    guard let edge = graph.edges[key] else { continue }
                    // must contain this route or same publicKey
                    let isRelevant: Bool = {
                        if edge.routeIDs.contains(routeID) { return true }
                        if let qk = queryPublicKey {
                            for rid in edge.routeIDs {
                                if graph.routeInfo[rid]?.publicKey == qk { return true }
                            }
                        }
                        return false
                    }()
                    if !isRelevant { continue }

                    // must be shared (2+ distinct publicKeys)
                    let distinct = Set(edge.routeIDs.compactMap { graph.routeInfo[$0]?.publicKey ?? "id:\($0)" })
                    if distinct.count < 2 && edge.routeIDs.count < 2 { continue }

                    // parallel check
                    let edx = edge.toPoint.x - edge.fromPoint.x
                    let edy = edge.toPoint.y - edge.fromPoint.y
                    let eLen = hypot(edx, edy)
                    guard eLen > 1e-9 else { continue }
                    let eUnitX = edx / eLen
                    let eUnitY = edy / eLen
                    let dot = abs(qUnitX * eUnitX + qUnitY * eUnitY)
                    if dot < minParallelDot { continue }

                    // distance from mid to edge
                    let distMap = distanceFromPointToSegment(point: mid, segFrom: edge.fromPoint, segTo: edge.toPoint)
                    let distMeters = distMap * mPerPoint
                    if distMeters > maxSeparationMeters { continue }

                    if distMap < bestDist {
                        bestDist = distMap
                        bestEdge = edge
                    }
                }
            }
        }

        guard let edge = bestEdge else { return nil }

        // Find rank
        var rank: Int? = nil
        if let qk = queryPublicKey {
            for (idx, repID) in edge.orderedRouteIDs.enumerated() {
                if let repInfo = graph.routeInfo[repID], repInfo.publicKey == qk {
                    rank = idx
                    break
                }
                if repID == routeID {
                    rank = idx
                    break
                }
            }
        } else {
            rank = edge.orderedRouteIDs.firstIndex(of: routeID)
        }
        guard let r = rank else { return nil }
        let offset = laneOffset(rank: r, totalLanes: edge.orderedRouteIDs.count, spacing: spacing)
        return (true, offset)
    }

    private static func distanceFromPointToSegment(point: MKMapPoint, segFrom: MKMapPoint, segTo: MKMapPoint) -> Double {
        let dx = segTo.x - segFrom.x
        let dy = segTo.y - segFrom.y
        let len2 = dx*dx + dy*dy
        guard len2 > 0 else { return point.distance(to: segFrom) }
        let t = max(0, min(1, ((point.x - segFrom.x)*dx + (point.y - segFrom.y)*dy)/len2))
        let proj = MKMapPoint(x: segFrom.x + t*dx, y: segFrom.y + t*dy)
        return point.distance(to: proj)
    }

    static func offsetsForPolyline(
        routeID: Int,
        polyline: [CLLocationCoordinate2D],
        graph: CorridorGraph,
        spacing: Double,
        gridSizeMeters: Double = CorridorGraphBuilder.defaultGridSizeMeters
    ) -> (offsets: [Double], shared: [Bool], edgeKeys: [CorridorDirectedEdgeKey?]) {
        guard polyline.count >= 2 else {
            return (Array(repeating: 0, count: polyline.count), Array(repeating: false, count: polyline.count), [])
        }

        let refLat = polyline.first?.latitude ?? 34.42
        let mPerPoint = CorridorGraphBuilder.metersPerMapPoint(atLatitude: refLat)
        let gridSizeMapPoints = gridSizeMeters / mPerPoint
        let mergeTolerance = gridSizeMapPoints * 1.5

        // Use graph's stored gridSizeMapPoints if available, else computed
        let effectiveGridSize = graph.gridSizeMapPoints > 0 ? graph.gridSizeMapPoints : gridSizeMapPoints
        let effectiveTolerance = effectiveGridSize * 1.5

        var snappedNodes: [CorridorGridNode] = []
        snappedNodes.reserveCapacity(polyline.count)
        var mapPoints: [MKMapPoint] = []
        mapPoints.reserveCapacity(polyline.count)

        let queryPublicKey = graph.routeInfo[routeID]?.publicKey

        for coord in polyline {
            let mp = MKMapPoint(coord)
            mapPoints.append(mp)
            if let nearest = nearestGraphNode(to: mp, graph: graph, gridSizeMapPoints: effectiveGridSize, tolerance: effectiveTolerance) {
                snappedNodes.append(nearest)
            } else {
                // No graph node nearby – quantize independently (will be isolated)
                let q = CorridorGridNode(
                    x: Int((mp.x / gridSizeMapPoints).rounded()),
                    y: Int((mp.y / gridSizeMapPoints).rounded())
                )
                snappedNodes.append(q)
            }
        }

        // Deduplicate consecutive identical nodes
        var dedupNodes: [CorridorGridNode] = []
        var dedupPoints: [MKMapPoint] = []
        var dedupOrigIndices: [Int] = []
        for (idx, node) in snappedNodes.enumerated() {
            if dedupNodes.last != node {
                dedupNodes.append(node)
                dedupPoints.append(mapPoints[idx])
                dedupOrigIndices.append(idx)
            }
        }

        var segmentEdgeKeys: [CorridorDirectedEdgeKey?] = []
        var segmentIsShared: [Bool] = []
        var segmentOffsets: [Double] = []

        for i in 0..<(dedupNodes.count - 1) {
            let fromNode = dedupNodes[i]
            let toNode = dedupNodes[i+1]
            if fromNode == toNode {
                segmentEdgeKeys.append(nil)
                segmentIsShared.append(false)
                segmentOffsets.append(0)
                continue
            }
            let key = CorridorDirectedEdgeKey(from: fromNode, to: toNode)
            segmentEdgeKeys.append(key)

            if let edge = graph.edges[key] {
                // Check if this edge is relevant for this route (same journey or same publicKey)
                let isRelevant: Bool = {
                    if edge.routeIDs.contains(routeID) { return true }
                    if let qk = queryPublicKey {
                        for rid in edge.routeIDs {
                            if graph.routeInfo[rid]?.publicKey == qk {
                                return true
                            }
                        }
                    }
                    return false
                }()

                if isRelevant {
                    let distinctPublicKeys = Set(edge.routeIDs.compactMap { graph.routeInfo[$0]?.publicKey ?? "id:\($0)" })
                    let isShared = distinctPublicKeys.count >= 2 || edge.routeIDs.count >= 2
                    segmentIsShared.append(isShared)
                    if isShared {
                        var rank: Int? = nil
                        if let qk = queryPublicKey {
                            for (idx, repID) in edge.orderedRouteIDs.enumerated() {
                                if let repInfo = graph.routeInfo[repID], repInfo.publicKey == qk {
                                    rank = idx
                                    break
                                }
                                if repID == routeID {
                                    rank = idx
                                    break
                                }
                            }
                        } else {
                            rank = edge.orderedRouteIDs.firstIndex(of: routeID)
                        }
                        if let r = rank {
                            segmentOffsets.append(laneOffset(rank: r, totalLanes: edge.orderedRouteIDs.count, spacing: spacing))
                        } else {
                            segmentOffsets.append(0)
                        }
                    } else {
                        segmentOffsets.append(0)
                    }
                } else {
                    // Exact edge exists but not relevant – try nearby parallel shared edge
                    if let (isShared, offset) = findNearbySharedEdge(
                        queryFrom: dedupPoints[i],
                        queryTo: dedupPoints[i+1],
                        routeID: routeID,
                        queryPublicKey: queryPublicKey,
                        graph: graph,
                        mPerPoint: mPerPoint,
                        spacing: spacing
                    ) {
                        segmentIsShared.append(isShared)
                        segmentOffsets.append(offset)
                    } else {
                        segmentIsShared.append(false)
                        segmentOffsets.append(0)
                    }
                }
            } else {
                // No exact edge – try nearby parallel shared edge within 20m (original corridor membership)
                if let (isShared, offset) = findNearbySharedEdge(
                    queryFrom: dedupPoints[i],
                    queryTo: dedupPoints[i+1],
                    routeID: routeID,
                    queryPublicKey: queryPublicKey,
                    graph: graph,
                    mPerPoint: mPerPoint,
                    spacing: spacing
                ) {
                    segmentIsShared.append(isShared)
                    segmentOffsets.append(offset)
                } else {
                    segmentIsShared.append(false)
                    segmentOffsets.append(0)
                }
            }
        }

        // --- Clean short shared runs and bridge short gaps to avoid squiggly flicker ---
        // Compute segment lengths in meters
        var segmentLengths: [Double] = []
        segmentLengths.reserveCapacity(dedupPoints.count - 1)
        for i in 0..<(dedupPoints.count - 1) {
            let d = dedupPoints[i].distance(to: dedupPoints[i+1]) * mPerPoint
            segmentLengths.append(d)
        }

        // Remove short shared runs (< 20m) – intersections, terminal bays, not real corridors
        let minSharedRunMeters: Double = 20
        var idx = 0
        while idx < segmentIsShared.count {
            if !segmentIsShared[idx] { idx += 1; continue }
            let runStart = idx
            var runLength: Double = 0
            while idx < segmentIsShared.count && segmentIsShared[idx] {
                runLength += segmentLengths[idx]
                idx += 1
            }
            let runEnd = idx - 1
            if runLength < minSharedRunMeters {
                for j in runStart...runEnd {
                    segmentIsShared[j] = false
                    segmentOffsets[j] = 0
                }
            }
        }

        // Bridge short gaps (< 60m) between shared runs with same offset – keeps ribbon straight
        let maxGapToBridge: Double = 60
        idx = 0
        while idx < segmentIsShared.count {
            // find shared run
            while idx < segmentIsShared.count && !segmentIsShared[idx] { idx += 1 }
            if idx >= segmentIsShared.count { break }
            let firstRunEnd = { () -> Int in
                var j = idx
                while j < segmentIsShared.count && segmentIsShared[j] { j += 1 }
                return j - 1
            }()
            // find next shared run
            var gapStart = firstRunEnd + 1
            var gapLength: Double = 0
            while gapStart < segmentIsShared.count && !segmentIsShared[gapStart] {
                gapLength += segmentLengths[gapStart]
                gapStart += 1
            }
            if gapStart >= segmentIsShared.count { break }
            // gap is from firstRunEnd+1 to gapStart-1
            if gapLength <= maxGapToBridge && gapLength > 0 {
                // Check if offsets on both sides are compatible (same side, similar magnitude within 1 spacing)
                let leftOffset = segmentOffsets[firstRunEnd]
                let rightOffset = segmentOffsets[gapStart]
                if abs(leftOffset - rightOffset) <= spacing * 0.6 {
                    // Bridge
                    for j in (firstRunEnd+1)..<gapStart {
                        segmentIsShared[j] = true
                        // Interpolate offset
                        let t = Double(j - (firstRunEnd+1)) / Double(max(1, gapStart - (firstRunEnd+1)))
                        segmentOffsets[j] = leftOffset * (1 - t) + rightOffset * t
                    }
                }
            }
            idx = gapStart
        }

        // Vertex offsets: average only shared adjacent segments, not isolated
        var vertexOffsets = Array(repeating: 0.0, count: dedupNodes.count)
        var vertexShared = Array(repeating: false, count: dedupNodes.count)
        var vertexEdgeKeys: [CorridorDirectedEdgeKey?] = Array(repeating: nil, count: dedupNodes.count)

        for i in 0..<dedupNodes.count {
            var sharedVals: [Double] = []
            var shared = false
            var key: CorridorDirectedEdgeKey? = nil
            if i > 0 && segmentIsShared[i-1] {
                sharedVals.append(segmentOffsets[i-1])
                shared = true
                key = segmentEdgeKeys[i-1] ?? key
            }
            if i < segmentOffsets.count && segmentIsShared[i] {
                sharedVals.append(segmentOffsets[i])
                shared = true
                key = key ?? segmentEdgeKeys[i]
            }
            if sharedVals.isEmpty {
                // If no shared adjacent, check if we are at transition: look one more step for tapering?
                // For now, keep 0
                vertexOffsets[i] = 0
                vertexShared[i] = false
                // Still keep edge key for trunk ownership
                if i > 0 { key = segmentEdgeKeys[i-1] ?? key }
                if i < segmentEdgeKeys.count { key = key ?? segmentEdgeKeys[i] }
            } else {
                vertexOffsets[i] = sharedVals.reduce(0, +) / Double(sharedVals.count)
                vertexShared[i] = shared
            }
            vertexEdgeKeys[i] = key
        }

        // Map back to original polyline indices
        var finalOffsets = Array(repeating: 0.0, count: polyline.count)
        var finalShared = Array(repeating: false, count: polyline.count)
        var finalEdgeKeys: [CorridorDirectedEdgeKey?] = Array(repeating: nil, count: polyline.count)

        var cursor = 0
        for origIdx in 0..<polyline.count {
            while cursor + 1 < dedupOrigIndices.count && dedupOrigIndices[cursor + 1] <= origIdx {
                cursor += 1
            }
            if cursor < vertexOffsets.count {
                finalOffsets[origIdx] = vertexOffsets[cursor]
                finalShared[origIdx] = vertexShared[cursor]
                finalEdgeKeys[origIdx] = vertexEdgeKeys[cursor]
            }
        }

        // Apply simple tapering at start/end of shared runs (58m) to avoid diagonal connectors
        // We have mapPoints and finalShared, need to taper offsets into isolated vertices
        let taperMeters: Double = 58
        let mPerPointLocal = mPerPoint
        // Compute cumulative distance along polyline
        var cumDist: [Double] = Array(repeating: 0, count: polyline.count)
        var total: Double = 0
        for i in 1..<polyline.count {
            total += mapPoints[i-1].distance(to: mapPoints[i]) * mPerPointLocal
            cumDist[i] = total
        }
        // Find shared runs and apply taper
        var i = 0
        while i < finalShared.count {
            while i < finalShared.count && !finalShared[i] { i += 1 }
            guard i < finalShared.count else { break }
            let runStart = i
            while i < finalShared.count && finalShared[i] { i += 1 }
            let runEnd = i - 1

            // Backward taper
            let startOffset = finalOffsets[runStart]
            let startDist = cumDist[runStart]
            for back in stride(from: runStart - 1, through: 0, by: -1) {
                if finalShared[back] { break }
                let dist = startDist - cumDist[back]
                if dist >= taperMeters { break }
                let factor = 1.0 - (dist / taperMeters)
                finalOffsets[back] = startOffset * factor
            }
            // Forward taper
            let endOffset = finalOffsets[runEnd]
            let endDist = cumDist[runEnd]
            for fwd in (runEnd + 1)..<finalShared.count {
                if finalShared[fwd] { break }
                let dist = cumDist[fwd] - endDist
                if dist >= taperMeters { break }
                let factor = 1.0 - (dist / taperMeters)
                finalOffsets[fwd] = endOffset * factor
            }
        }

        // Stabilize corridor run offsets – blend among still-shared vertices within 72m so lane doesn't jump
        let transitionDistance: Double = 72
        let originalOffsets = finalOffsets
        var stabilized = finalOffsets
        for idx in finalOffsets.indices where finalShared[idx] {
            var weightedSum = originalOffsets[idx]
            var weightTotal = 1.0
            var dist: Double = 0
            var back = idx
            while back > 0 {
                dist += abs(cumDist[back] - cumDist[back-1])
                if dist > transitionDistance { break }
                guard finalShared[back-1] else { break }
                let w = 1.0 - dist / transitionDistance
                weightedSum += originalOffsets[back-1] * w
                weightTotal += w
                back -= 1
            }
            dist = 0
            var fwd = idx
            while fwd < originalOffsets.count - 1 {
                dist += abs(cumDist[fwd+1] - cumDist[fwd])
                if dist > transitionDistance { break }
                guard finalShared[fwd+1] else { break }
                let w = 1.0 - dist / transitionDistance
                weightedSum += originalOffsets[fwd+1] * w
                weightTotal += w
                fwd += 1
            }
            stabilized[idx] = weightedSum / weightTotal
        }
        finalOffsets = stabilized

        return (finalOffsets, finalShared, finalEdgeKeys)
    }

    static func offsetsForDensifiedPolyline(
        routeID: Int,
        polyline: [CLLocationCoordinate2D],
        graph: CorridorGraph,
        spacing: Double,
        gridSizeMeters: Double = CorridorGraphBuilder.defaultGridSizeMeters
    ) -> (coordinates: [CLLocationCoordinate2D], offsets: [Double], shared: [Bool], edgeKeys: [CorridorDirectedEdgeKey?]) {
        let refLat = polyline.first?.latitude ?? 34.42
        let mPerPoint = CorridorGraphBuilder.metersPerMapPoint(atLatitude: refLat)
        let densified = CorridorGraphBuilder.densifiedCoordinates(polyline, maxSegmentMeters: CorridorGraphBuilder.densifyMeters, mPerPoint: mPerPoint)
        let (offsets, shared, edgeKeys) = offsetsForPolyline(routeID: routeID, polyline: densified, graph: graph, spacing: spacing, gridSizeMeters: gridSizeMeters)
        return (densified, offsets, shared, edgeKeys)
    }
}

// MARK: - Caching per GTFS feed version (step 6)

final class CorridorGraphCache {
    static let shared = CorridorGraphCache()

    private struct CachedEntry {
        let graph: CorridorGraph
        let timestamp: Date
    }

    private var cache: [String: CachedEntry] = [:]
    private let queue = DispatchQueue(label: "corridor.cache.queue", attributes: .concurrent)

    private init() {}

    static func feedVersionHash(for inputs: [CorridorRouteInput]) -> String {
        var hasher = Hasher()
        for input in inputs.sorted(by: { $0.id < $1.id }) {
            hasher.combine(input.id)
            hasher.combine(input.publicKey)
            hasher.combine(input.polylines.count)
            for polyline in input.polylines {
                hasher.combine(polyline.count)
                if let first = polyline.first {
                    hasher.combine(first.latitude.bitPattern)
                    hasher.combine(first.longitude.bitPattern)
                }
                if let last = polyline.last {
                    hasher.combine(last.latitude.bitPattern)
                    hasher.combine(last.longitude.bitPattern)
                }
            }
        }
        return String(hasher.finalize())
    }

    func graph(
        for inputs: [CorridorRouteInput],
        gridSizeMeters: Double = CorridorGraphBuilder.defaultGridSizeMeters
    ) -> CorridorGraph {
        let versionHash = Self.feedVersionHash(for: inputs)

        var cached: CachedEntry?
        queue.sync {
            cached = cache[versionHash]
        }
        if let cached, cached.graph.feedVersionHash == versionHash {
            return cached.graph
        }

        var graph = CorridorGraphBuilder.build(
            from: inputs,
            gridSizeMeters: gridSizeMeters,
            feedVersionHash: versionHash
        )
        CorridorLaneOrdering.computeStableOrder(for: &graph)

        let entry = CachedEntry(graph: graph, timestamp: Date())
        queue.sync(flags: .barrier) {
            self.cache[versionHash] = entry
            if self.cache.count > 5 {
                let sorted = self.cache.sorted { $0.value.timestamp < $1.value.timestamp }
                for (key, _) in sorted.dropLast(5) {
                    self.cache.removeValue(forKey: key)
                }
            }
        }

        return graph
    }

    func clear() {
        queue.sync(flags: .barrier) {
            self.cache.removeAll()
        }
    }
}

// MARK: - Integration helper

struct CorridorMapRendering {
    static func laneLayouts(
        for journeys: [RouteJourney],
        spacing: Double
    ) -> [Int: [CorridorLaneLayout]] {
        let inputs = journeys.enumerated().map { idx, journey in
            let publicKey = "\(journey.route.agencyName)|\(journey.route.routeNumber ?? journey.route.shortName)"
            return CorridorRouteInput(
                id: journey.id,
                polylines: journey.flagshipPolylines,
                publicKey: publicKey,
                agencyName: journey.route.agencyName,
                routeNumber: journey.route.routeNumber ?? journey.route.shortName,
                directionID: journey.directionID,
                observedDepartureCount: journey.observedDepartureCount,
                stackOrder: idx
            )
        }

        let graph = CorridorGraphCache.shared.graph(for: inputs)

        var result: [Int: [CorridorLaneLayout]] = [:]

        for journey in journeys {
            var layouts: [CorridorLaneLayout] = []
            for polyline in journey.flagshipPolylines where polyline.count >= 2 {
                let (densified, vertexOffsets, vertexShared, edgeKeys) = CorridorLaneRendering.offsetsForDensifiedPolyline(
                    routeID: journey.id,
                    polyline: polyline,
                    graph: graph,
                    spacing: spacing
                )

                var trunkOwner = Array(repeating: false, count: densified.count)
                for i in 0..<densified.count {
                    if let ek = edgeKeys[i], let edge = graph.edges[ek], edge.routeIDs.count >= 2 || Set(edge.routeIDs.compactMap { graph.routeInfo[$0]?.publicKey }).count >= 2 {
                        // Check if this journey's publicKey is dominant
                        if let firstRep = edge.orderedRouteIDs.first,
                           let firstInfo = graph.routeInfo[firstRep],
                           let myInfo = graph.routeInfo[journey.id] {
                            trunkOwner[i] = firstInfo.publicKey == myInfo.publicKey
                        } else {
                            trunkOwner[i] = edge.orderedRouteIDs.first == journey.id
                        }
                    }
                }

                layouts.append(CorridorLaneLayout(
                    coordinates: densified,
                    offsets: vertexOffsets,
                    sharedVertices: vertexShared,
                    trunkOwnerVertices: trunkOwner
                ))
            }
            result[journey.id] = layouts
        }

        return result
    }
}

// MARK: - Shared types

struct CorridorLaneLayout {
    let coordinates: [CLLocationCoordinate2D]
    let offsets: [Double]
    let sharedVertices: [Bool]
    let trunkOwnerVertices: [Bool]
}
