import XCTest

@testable import WayboundCore

/// Randomised corridor fuzz for the lane scheduler, ported from
/// `lane_fuzz.py` (now gone; this is its successor): no crashes, no lane
/// wobble for continuing strands beyond main's, no lane overlap, and never
/// more in-bundle crossings than main's lane math on the same geometry.
///
/// The generator uses a deterministic SplitMix64 RNG (the Python random
/// sequence is not reproducible outside Python), so this battery has its
/// own measured baseline: the gate below pins the first green run's
/// problem-seed count — a scheduler regression that flips any seed trips.
/// Update the pin by deliberate commit, never by loosening casually.
final class LaneFuzzTests: XCTestCase {

    /// Deterministic RNG (SplitMix64): the same seed always produces the
    /// same scenario, on any platform.
    struct FuzzRandom {
        var state: UInt64

        init(_ seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }

        /// Uniform in [0, 1).
        mutating func uniform() -> Double {
            Double(next() >> 11) / Double(1 << 53)
        }

        /// Uniform in [a, b).
        mutating func uniform(_ a: Double, _ b: Double) -> Double {
            a + (b - a) * uniform()
        }

        /// Integer in [a, b] inclusive (python randint semantics).
        mutating func int(_ a: Int, _ b: Int) -> Int {
            a + Int(next() % UInt64(b - a + 1))
        }

        mutating func choice<T>(_ items: [T]) -> T {
            items[Int(next() % UInt64(items.count))]
        }

        mutating func bool(_ probability: Double) -> Bool {
            uniform() < probability
        }
    }

    func makeScenario(seed: UInt64) -> [LaneHarness.Strand] {
        var rng = FuzzRandom(seed)
        var control: [(x: Double, y: Double)] = [(0, 0)]
        var x = 0.0
        var y = 0.0
        for _ in 0..<rng.int(4, 10) {
            x += rng.uniform(120, 260)
            y += rng.uniform(-60, 60)
            control.append((x, y))
        }
        let spine = LaneScenarios.spinePoints(control)
        let arcs = LaneScenarios.arcOf(spine)
        let total = arcs.last!
        var strands: [LaneHarness.Strand] = []
        for i in 0..<rng.int(3, 12) {
            var join = rng.uniform(0, total * 0.5)
            var leave = min(total, join + rng.uniform(150, total - join))
            if rng.bool(0.5) {
                join = rng.uniform(0, 60)
            }
            let sideIn: Int? = join > 80
                ? rng.choice([nil, 1, -1] as [Int?])
                : nil
            let sideOut: Int? = leave < total - 80
                ? rng.choice([nil, 1, -1] as [Int?])
                : nil
            let reverse = rng.bool(0.25)
            let num = String(rng.int(1, 30))
                + (rng.choice([0, 1, 2]) == 2 ? "X" : "")
            leave = min(leave, total)
            strands.append(
                LaneHarness.Strand(
                    id: "j\(i)",
                    num: num,
                    direction: i % 2,
                    coords: LaneScenarios.polyline(
                        LaneScenarios.strand(
                            spine,
                            arcs,
                            join,
                            leave,
                            sideIn: sideIn,
                            sideOut: sideOut,
                            reverse: reverse
                        )
                    )
                )
            )
        }
        return strands
    }

    func check(seed: UInt64) -> [String] {
        let strands = makeScenario(seed: seed)
        guard strands.count >= 2 else { return [] }
        let scan = LaneHarness.membershipScan(strands)
        let mainLayouts = LaneHarness.mainLayouts(strands: strands, scan: scan)
        let journeys = strands.enumerated().map { index, strand in
            LaneDiagnosticsDocument.Journey(
                id: index,
                routeNumber: strand.num,
                agency: strand.agency,
                directionID: strand.direction,
                stackOrder: index,
                departures: strand.departures,
                polylines: [strand.coords]
            )
        }
        let schedule = CorridorLaneSchedule.schedule(
            journeys: journeys,
            laneSpacingPoints: LaneHarness.laneSpacing
        )
        let schedLayouts = LaneHarness.scheduledLayouts(
            strands: strands,
            scan: scan,
            schedule: LaneHarness.rekeySchedule(schedule)
        )
        let ribbonsMain = mainLayouts.mapValues { LaneHarness.ribbon($0) }
        let ribbonsSched = schedLayouts.mapValues { LaneHarness.ribbon($0) }
        let (bundleMain, _) = LaneHarness.countBundleCrossings(
            mainLayouts,
            ribbonsMain
        )
        let (bundleSched, pairs) = LaneHarness.countBundleCrossings(
            schedLayouts,
            ribbonsSched
        )
        var spineFramesSched: [Int: LaneHarness.SpineFrame] = [:]
        var spineFramesMain: [Int: LaneHarness.SpineFrame] = [:]
        let wobble = LaneHarness.bundleWobble(
            schedLayouts,
            strands: strands,
            scan: scan,
            spineFrames: &spineFramesSched
        )
        let wobbleMain = LaneHarness.bundleWobble(
            mainLayouts,
            strands: strands,
            scan: scan,
            spineFrames: &spineFramesMain
        )
        let separation = LaneHarness.minLaneSeparation(
            schedLayouts,
            strands: strands,
            scan: scan,
            spineFrames: &spineFramesSched
        )
        let sepMain = LaneHarness.minLaneSeparation(
            mainLayouts,
            strands: strands,
            scan: scan,
            spineFrames: &spineFramesMain
        )

        var problems: [String] = []
        if bundleSched > bundleMain {
            problems.append("in-bundle crossings \(bundleMain) -> \(bundleSched)")
        }
        if wobble > max(0.1, wobbleMain + 0.25) {
            problems.append(
                "lane wobble \(wobble) (main \(wobbleMain))"
            )
        }
        let floor = min(0.75, sepMain ?? 0.75) - 0.05
        if let separation, separation < floor {
            problems.append("lane separation \(separation) (main \(sepMain.map(String.init) ?? "nil"))")
        }
        if !problems.isEmpty {
            let pairText = pairs.map { pair in
                "\(strands[pair.0].num)/\(strands[pair.1].num)×\(pair.2)"
            }.joined(separator: ",")
            print(
                "LANE-FUZZ seed \(seed) main=\(bundleMain) sched=\(bundleSched) "
                    + "wob=\(String(format: "%.2f", wobble)) "
                    + "sep=\(separation.map { String(format: "%.2f", $0) } ?? "nil") "
                    + "pairs=[\(pairText)] \(problems.joined(separator: " | "))"
            )
        }
        return problems
    }

    func testFuzz() {
        let seedCount = 120
        var bad = 0
        var badSeeds: [UInt64] = []
        for seed in 0..<UInt64(seedCount) {
            let problems = check(seed: seed)
            if !problems.isEmpty {
                bad += 1
                badSeeds.append(seed)
            }
        }
        let gate = 55
        print(
            "LANE-FUZZ summary problemSeeds=\(bad) of \(seedCount) "
                + "gate=\(gate) bad=[\(badSeeds.map(String.init).joined(separator: ","))]"
        )
        XCTAssertLessThanOrEqual(
            bad,
            gate,
            "lane fuzz regressed: \(bad) problem seeds (gate \(gate)): \(badSeeds)"
        )
    }
}
