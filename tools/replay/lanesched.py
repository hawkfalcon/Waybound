"""Candidate corridor lane scheduler: subway-style anchored lanes.

Main re-derives every strand's lane from the *currently* parallel member set,
so each join/leave slides the whole stack by half a lane and mid-sort joiners
cut through the bundle. This module replaces only that lane choice:

  * one pass per connected group of shared runs ("corridor")
  * a strand's lane is chosen once, when it enters the corridor, and is held
    for as long as it continues — continuing strands never move
  * joiners enter at the outer edge of the side they approach from
  * leavers keep their lane and peel away; freed slots are remembered so a
    dropout-and-return reclaims its own lane
  * the corridor-birth order is exit-aware: the first strand to peel off on
    a side sits outermost on that side, which minimises fork crossings
  * opposite travel directions stay on opposite sides of the centreline
    (direction split), as on main

The schedule stores, per (journey, segment), the lane offset expressed
against the sweeping spine's travel direction at that sample plus the sticky
reference journey. Observers convert into their own frame with the same
direction dot the shipped code already uses for its local stack.

Run:  python3 tools/replay/lane_check.py   (gates exit non-zero on failure)
"""
import math
import os
import sys
from collections import defaultdict

DEBUG = bool(os.environ.get("LANESCHED_DEBUG"))

sys.path.insert(0, ".")
from corridor2 import LS
from corridor3 import membership_scan, sorted_members, MIN_SHARED_DISTANCE
from geo import mpm, dist

JOIN_MIN = 30.0            # presence stretch shorter than this is not a join
GAP_BRIDGE = 150.0         # presence dropouts up to this hold their lane
GAP_CHORD_RATIO = 0.75     # straight-path gate for holding a lane through one
SIDE_LOOKAHEAD = 45.0      # metres of own geometry read for a join side
EXIT_LOOKAHEAD = 120.0     # metres walked to decide a departure side
SIDE_DEADBAND = 2.0        # metres off the reference line before a side counts
EXIT_ANGLE = 0.025         # a departure must also diverge faster than ~1.4
                           # degrees: gentle same-street curvature stays a
                           # stayer however far the walk runs
CENTRE_CLEARANCE = LS / 4  # how close opposite groups may approach the spine
SLOT_CLEARANCE = 0.6 * LS  # offsets closer than this to a slot collide


class LaneSample:
    __slots__ = ("offset", "dx", "dy", "ref_id")

    def __init__(self, offset, dx, dy, ref_id):
        self.offset = offset   # lane points, against (dx, dy) travel
        self.dx = dx
        self.dy = dy
        self.ref_id = ref_id


def _side_sign(point, origin, direction, m):
    """+1 left of travel, -1 right, None essentially on the line."""
    lx, ly = -direction[1], direction[0]
    s = (point[0] - origin[0]) * lx + (point[1] - origin[1]) * ly
    if abs(s) * m < 2.0:
        return None
    return 1 if s > 0 else -1


def schedule_lanes(geoms, scan):
    """{(journey id, segment index): LaneSample} for every shared segment."""
    arcs = {jid: g.arc() for jid, g in geoms.items()}
    m = mpm(next(iter(geoms.values())).coords[0][0])

    # ---- runs: maximal sharing stretches per journey, >= 30 m
    runs = []
    for jid, g in geoms.items():
        rows = scan[jid]
        i, n = 0, len(rows)
        while i < n:
            if rows[i]:
                j = i + 1
                while j < n and rows[j]:
                    j += 1
                if arcs[jid][j] - arcs[jid][i] >= MIN_SHARED_DISTANCE:
                    runs.append((jid, i, j))
                i = j
            else:
                i += 1

    # ---- corridor groups: union runs whose journeys share members
    parent = list(range(len(runs)))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    runs_by_jid = defaultdict(list)
    for idx, r in enumerate(runs):
        runs_by_jid[r[0]].append(idx)
    for idx, (jid, s0, s1) in enumerate(runs):
        members = set()
        for si in range(s0, s1):
            members.update(scan[jid][si])
        for cid in members:
            for cidx in runs_by_jid.get(cid, ()):
                ra, rb = find(idx), find(cidx)
                if ra != rb:
                    parent[ra] = rb

    groups = defaultdict(list)
    for idx in range(len(runs)):
        groups[find(idx)].append(idx)

    schedule = {}
    for root in sorted(groups, key=lambda r: -len(groups[r])):
        # Birth priority: the sweep whose spine follows the BUNDLE longest
        # (median member presence) runs first, so ladders are laid by a
        # spine with truthful presence for its members. Raw run length is
        # the wrong key: a spine that drags one express partner down a
        # freeway (long run, stub presence for everyone else — the transit
        # center stub) would otherwise birth a scrambled ladder that every
        # later sweep adopts.
        def _coverage(idx):
            jid, s0, s1 = runs[idx]
            rows = scan[jid]
            members = set()
            for si in range(s0, s1):
                members.update(rows[si] or ())
            lens = []
            for cid in members:
                if cid == jid:
                    continue
                n = sum(1 for si in range(s0, s1)
                        if rows[si] and cid in rows[si])
                if n:
                    lens.append(n)
            lens.sort()
            median = lens[len(lens) // 2] if lens else 0
            length = arcs[jid][s1] - arcs[jid][s0]
            return (-median, -length, jid)

        run_idxs = sorted(groups[root], key=_coverage)
        memory = {}   # public key -> freed offset, for re-entry
        for run_idx in run_idxs:
            _sweep(geoms, scan, arcs, m, runs, run_idx, schedule, memory)
    _post_fill(geoms, scan, arcs, schedule)
    _prune_islands(schedule)
    return schedule


def _prune_islands(schedule):
    """One-seg lattice islands: where several corridors' sweeps overlap
    geographically (streets meeting at a corner, a sliver run bridged
    into two sweeps), the first sweep to record an own segment can plant
    the OTHER corridor's lattice value there — a lone entry jumping a
    lane and a half from both neighbours inside an otherwise constant
    run. Drop it and let the bridge fill the slot continuously."""
    by_strand = {}
    for (cid, k), e in schedule.items():
        by_strand.setdefault(cid, {})[k] = e.offset
    for cid, offs in by_strand.items():
        for k in sorted(offs):
            if (k - 1 not in offs or k + 1 not in offs):
                continue
            a, b, c = offs[k - 1], offs[k], offs[k + 1]
            if (abs(b - a) > 1.5 * LS and abs(b - c) > 1.5 * LS
                    and abs(a - c) <= LS):
                del schedule[(cid, k)]


def _debounced_presence(rows, s0, s1, cid, arcs):
    """Presence stretches of cid over the sweep: dropouts up to GAP_BRIDGE
    merge, stretches under JOIN_MIN drop — the same smoothing the observer's
    run prune and gap bridge already apply."""
    present = [cid in rows[si] for si in range(s0, s1)]
    stretches = []
    i = 0
    while i < len(present):
        if present[i]:
            j = i + 1
            while j < len(present) and present[j]:
                j += 1
            stretches.append([s0 + i, s0 + j])
            i = j
        else:
            i += 1
    if not stretches:
        return []
    bridged = [stretches[0]]
    for a, b in stretches[1:]:
        prev_end = bridged[-1][1]
        if arcs[a] - arcs[prev_end] <= GAP_BRIDGE:
            bridged[-1][1] = max(prev_end, b)
        else:
            bridged.append([a, b])
    return [(a, b) for a, b in bridged if arcs[b] - arcs[a] >= JOIN_MIN]


def _sweep(geoms, scan, arcs, m, runs, run_idx, schedule, memory):
    jid, s0, s1 = runs[run_idx]
    g = geoms[jid]
    rows = scan[jid]
    mm = mpm(g.coords[0][0])

    presence = {jid: [(s0, s1)]}
    for cid in sorted({c for si in range(s0, s1) for c in rows[si]}):
        stretches = _debounced_presence(rows, s0, s1, cid, arcs[jid])
        if stretches:
            presence[cid] = stretches

    def seg_dir(si):
        seg = g.segs[si] or g.segs[max(s0, si - 1)]
        return (seg.ux, seg.uy)

    def matched(cid, si):
        return rows[si].get(cid) if rows[si] else None

    def own_index(cid, si):
        """Start index on cid's own polyline of its segment matched at si."""
        hit = matched(cid, si)
        return None if hit is None else geoms[cid].seg_index.get(id(hit))

    def nearest_own_index(cid, si):
        """Own index of cid's nearest match when si itself has none."""
        best, best_d = None, None
        for probe in range(max(s0, si - 24), min(s1, si + 24)):
            hit = matched(cid, probe)
            if hit is None:
                continue
            d = abs(probe - si)
            if best_d is None or d < best_d:
                best_d, best = d, probe
        if best is None:
            return None
        return own_index(cid, best)

    def join_side(cid, si):
        """Side cid approaches from, against the spine's travel at si."""
        k = own_index(cid, si)
        if k is None or k <= 0:
            return None
        cg = geoms[cid]
        back, travelled = k, 0.0
        while back > 0 and travelled < SIDE_LOOKAHEAD:
            travelled += dist(cg.points[back - 1], cg.points[back]) * mm
            back -= 1
        seg = g.segs[si] or g.segs[si - 1]
        return _side_sign(cg.points[back], seg.s, seg_dir(si), mm)

    def exit_side(cid, out_si):
        """Side cid leaves toward once its presence stretch ends. Walks the
        strand's own polyline up to EXIT_LOOKAHEAD, stopping at the first
        point clearly off the spine line: a gentle fork (ramp merge angle)
        takes tens of metres to clear the deadband, which a fixed short
        window used to read as 'stays on'."""
        hit, probe = None, None
        for si in range(min(out_si, s1 - 1), s0 - 1, -1):
            hit = matched(cid, si)
            if hit is not None:
                probe = si
                break
        if hit is None:
            return None
        k = geoms[cid].seg_index.get(id(hit))
        if k is None:
            return None
        cg = geoms[cid]
        if k >= len(cg.points) - 1:
            return None
        seg = g.segs[probe]
        d = seg_dir(probe)
        lx, ly = -d[1], d[0]
        fwd, travelled = k, 0.0
        while fwd < len(cg.points) - 1 and travelled < EXIT_LOOKAHEAD:
            s = ((cg.points[fwd][0] - seg.s[0]) * lx
                 + (cg.points[fwd][1] - seg.s[1]) * ly)
            if abs(s) * mm >= max(SIDE_DEADBAND, EXIT_ANGLE * travelled):
                return 1 if s > 0 else -1
            travelled += dist(cg.points[fwd], cg.points[fwd + 1]) * mm
            fwd += 1
        return None

    def group_sign(cid, si):
        k = own_index(cid, si)
        if k is None:
            return 1
        seg = geoms[cid].segs[k]
        d = seg_dir(si)
        return 1 if seg.ux * d[0] + seg.uy * d[1] >= 0 else -1

    # ---- sweep state -----------------------------------------------------
    slots = {}         # public key -> offset, spine frame
    slot_groups = {}   # public key -> direction sign (+1 with the spine)
    sticky_ref = [None]

    def key_of(cid):
        return geoms[cid].key()

    def present_journeys(si):
        out = [cid for cid, st in presence.items()
               if any(a <= si < b for a, b in st)]
        return sorted_members(geoms, out)

    def present_keys(si):
        seen, keys = set(), []
        for cid in present_journeys(si):
            k = key_of(cid)
            if k not in seen:
                seen.add(k)
                keys.append(k)
        return keys

    def occupied():
        return list(slots.values())

    def free_slot(cand, step):
        while any(abs(cand - v) < SLOT_CLEARANCE for v in occupied()):
            cand += step
        return cand

    def crosses_centre(cand, gsign):
        if not any(sg == -gsign for sg in slot_groups.values()):
            return False
        return cand * gsign < CENTRE_CLEARANCE

    def group_offsets(gsign):
        return [v for k, v in slots.items() if slot_groups[k] == gsign]

    def outermost(gofs, outward):
        return max(gofs) if outward > 0 else min(gofs)

    def innermost(gofs, outward):
        return min(gofs) if outward > 0 else max(gofs)

    def travels_far(cid, si):
        """True when cid runs well past si — a stayer. A stayer stacked
        outside extreme adopted slots (freed in some wider corridor
        context) would drift lanes off the street once those peel; a
        leaver must sit outside however wide the momentary bundle is."""
        stretches = presence.get(cid, [])
        for idx, (a, b) in enumerate(stretches):
            if a <= si < b:
                if b - si > 24:
                    return True
                # Terminal stretch: the route ends here rather than
                # peeling onto another street — treat as a stayer.
                if idx == len(stretches) - 1 and b - si > 8:
                    own = own_index(cid, b - 1)
                    if own is None:
                        own = nearest_own_index(cid, b - 1)
                    n_own = len(geoms[cid].segs)
                    return own is not None and own >= n_own - 3
                return False
        return False

    def stable_bound(cid, si):
        """(centre, width, n) of the lane band the members that actually
        travel with cid justify: those present (or joining within the next
        few segments) whose presence runs well past si. Strands about to
        peel do not count — however extreme their slots, the bundle
        collapses the moment they leave. The centre is the stable
        companions' placed median when known (the band is relative to the
        bundle, not the spine zero)."""
        n = 1
        comp = []
        b_cid = next((b for a, b in presence.get(cid, []) if a <= si < b),
                     si + 25)
        # Tail companionship (riding with cid to the end of its overlap)
        # only means something when cid really ends here — its route
        # finishing — rather than the sweep's run merely stopping.
        own_end = own_index(cid, b_cid - 1)
        if own_end is None:
            own_end = nearest_own_index(cid, b_cid - 1)
        terminal = (own_end is not None
                    and own_end >= len(geoms[cid].segs) - 3)
        for m in presence:
            if m == cid:
                continue
            rides = False
            for a, b in presence[m]:
                if a <= si + 24 and (b > si + 24
                                     or (terminal and b >= b_cid - 6)):
                    rides = True
                    break
            if not rides:
                continue
            n += 1
            mk = key_of(m)
            if mk in slots:
                comp.append(slots[mk])
        # n == 1: no stable companion is even present — the strand is on
        # its own here and its own prior entries are its continuity.
        if comp:
            comp.sort()
            mid = len(comp) // 2
            if len(comp) % 2:
                centre = comp[mid]
            else:
                centre = (comp[mid - 1] + comp[mid]) / 2.0
            return centre, LS / 2 * n, n
        # No placed stable companion: judge against the spine zero.
        return None, LS / 2 * n, n

    def place(cid, side, gsign, numeric_rank, si=None):
        """Pick this joiner's slot: outside on its approach side, never
        crossing the centreline into the opposing direction group."""
        gofs = group_offsets(gsign)
        outward = 1 if gsign >= 0 else -1
        stayer = si is not None and travels_far(cid, si)
        band = None
        if stayer:
            centre, width, _n = stable_bound(cid, si)
            band = (centre if centre is not None else 0.0, width)

        def fits(cand):
            return (band is None
                    or abs(cand - band[0]) <= band[1] + 1e-9)
        if not gofs:
            slots_for_group = LS / 2 * gsign
            if all(abs(slots_for_group - v) >= SLOT_CLEARANCE
                   for v in occupied()):
                return slots_for_group
            return free_slot(slots_for_group, LS / 2 * outward)
        if side is None:
            if stayer:
                # A stayer with no approach side (born on this corridor or
                # riding it to its end) belongs NEXT to the members it
                # actually travels with — never stacked outside strangers
                # whose extreme slots peel off in a few segments.
                comp_slots = [slots[k] for k in slots
                              if k != key_of(cid) and _stays_key(k, si)]
                if comp_slots:
                    comps = sorted(comp_slots)
                    target = comps[len(comps) // 2]
                else:
                    target = LS / 2 * gsign
                occ = occupied()
                for step in range(0, 30):
                    cands = ((target,) if step == 0 else
                             ((target + LS * step, target - LS * step)
                              if target >= 0 else
                              (target - LS * step, target + LS * step)))
                    for cand in cands:
                        if any(abs(cand - v) < SLOT_CLEARANCE for v in occ):
                            continue
                        if crosses_centre(cand, gsign):
                            continue
                        if not fits(cand):
                            continue
                        return cand
                return free_slot(target, LS / 2 * outward)
            # A leaver born on the corridor: prefer the slot its numeric
            # identity suggests, else step outward.
            ordered = sorted(gofs)
            if numeric_rank >= len(ordered):
                target = outermost(gofs, outward) + LS * outward
            else:
                target = ordered[numeric_rank] if outward > 0 \
                    else list(reversed(ordered))[numeric_rank]
            if all(abs(target - v) >= SLOT_CLEARANCE for v in occupied()):
                return target
            return free_slot(target, LS / 2 * outward)
        if DEBUG:
            print(f"      PLACE {geoms[cid].num} side={side} gsign={gsign}"
                  f" rank={numeric_rank} band={band}"
                  f" slots={dict((k, round(v, 1)) for k, v in slots.items())}",
                  file=sys.stderr)
        if side == outward:
            base = outermost(gofs, outward) + LS * outward
            cand = free_slot(base, LS / 2 * outward)
            if fits(cand):
                return cand
        else:
            base = innermost(gofs, outward) - LS * outward
            if not crosses_centre(base, gsign):
                cand = free_slot(base, -LS / 2 * outward)
                if not crosses_centre(cand, gsign) and fits(cand):
                    return cand
        if band is not None:
            # Outside the band the stable membership justifies: take the
            # free rung nearest the band centre, stepping outward within
            # the band — the wide adopted extremes peel off shortly.
            centre, width = band
            occupied_all = occupied()
            for step in range(0, len(occupied_all) + 14):
                for sign_step in ((1, -1) if centre >= 0 else (-1, 1)):
                    cand = centre + sign_step * step * LS
                    if any(abs(cand - v) < SLOT_CLEARANCE
                           for v in occupied_all):
                        continue
                    if crosses_centre(cand, gsign):
                        continue
                    if abs(cand - centre) > width:
                        continue
                    return cand
        base = outermost(gofs, outward) + LS * outward
        return free_slot(base, LS / 2 * outward)

    def _stays_key(k, si):
        return any(key_of(cid) == k and travels_far(cid, si)
                   for cid in presence)

    def adopt_existing(si):
        """Pull already-scheduled lanes into this sweep's state (converted
        to the spine frame) so chained sweeps stay consistent. Entries live
        in each member's own sample frame: resolve this sample's index on
        the member's polyline before searching. The spine's own entries are
        keyed in its frame already."""
        for cid in present_journeys(si):
            k = key_of(cid)
            if k in slots:
                continue
            if cid == jid:
                own = si
            else:
                own = own_index(cid, si)
                if own is None:
                    own = nearest_own_index(cid, si)
            if own is None:
                continue
            entry = _nearest_entry(schedule, cid, own)
            if entry is None:
                continue
            d = seg_dir(si)
            sign = 1 if entry.dx * d[0] + entry.dy * d[1] >= 0 else -1
            adopted = entry.offset * sign
            if travels_far(cid, si):
                centre, width, n_stable = stable_bound(cid, si)
                if n_stable > 1 and abs(adopted - (centre or 0.0)) > width:
                    # Context-foreign slot: the entry was set in some
                    # other corridor's lattice (an express stub where
                    # this strand was a momentary outer leaver). A stayer
                    # here must not inherit it five lanes out — leave it
                    # for placement.
                    continue
            slots[k] = adopted
            slot_groups[k] = group_sign(cid, si)

    def consensus_direction(si, members):
        """Average travel direction at si of the given members' matched
        segments, aligned to the spine's frame. Robust to any single
        polyline turning: the street is what the group does."""
        xs, ys = 0.0, 0.0
        d = seg_dir(si)
        for cid in members:
            seg = None
            for delta in (0, 1, -1, 2, -2, 3, -3):
                probe = si + delta
                if probe < s0 or probe >= len(rows):
                    continue
                hit = matched(cid, probe)
                if hit is None:
                    continue
                k = geoms[cid].seg_index.get(id(hit))
                seg = (geoms[cid].segs[k]
                       if k is not None and k < len(geoms[cid].segs)
                       else None)
                if seg is not None:
                    break
            if seg is None:
                continue
            s = 1 if seg.ux * d[0] + seg.uy * d[1] >= 0 else -1
            xs += s * seg.ux
            ys += s * seg.uy
        xs += d[0]
        ys += d[1]
        length = math.hypot(xs, ys)
        if length < 1e-6:
            return d
        return (xs / length, ys / length)

    def departure_side(cid, out_si):
        """Side on which cid leaves the corridor at out_si, measured against
        the members that REMAIN at that point — the street continues with
        them, so the consensus of the remainder, not any one polyline, is
        the reference."""
        probe = max(s0, min(out_si, s1) - 1)
        hit = None
        while probe >= s0:
            hit = matched(cid, probe)
            if hit is not None:
                break
            probe -= 1
        if hit is None:
            return None
        k = geoms[cid].seg_index.get(id(hit))
        if k is None:
            return None
        cg = geoms[cid]
        remaining = [c for c in present_journeys(probe)
                     if c != cid
                     and any(a <= probe < b for a, b in presence.get(c, []))]
        direction = consensus_direction(
            probe, remaining) if remaining else seg_dir(probe)
        if direction is None:
            return None
        # Walk the strand's own path forward, stopping at the first point
        # clearly off the street-consensus line (origin on the strand's
        # own point at the probe: immune to the few-metre baseline offsets
        # between matched polylines). A gentle fork takes tens of metres
        # to clear the deadband; a fixed short window reads it as a stayer.
        lx, ly = -direction[1], direction[0]
        fwd, travelled = k, 0.0
        while fwd < len(cg.points) - 1 and travelled < EXIT_LOOKAHEAD:
            s = ((cg.points[fwd][0] - cg.points[k][0]) * lx
                 + (cg.points[fwd][1] - cg.points[k][1]) * ly)
            if abs(s) * mm >= max(SIDE_DEADBAND, EXIT_ANGLE * travelled):
                return 1 if s > 0 else -1
            travelled += dist(cg.points[fwd], cg.points[fwd + 1]) * mm
            fwd += 1
        return None


    def birth(si):
        """Order a corridor's first bundle. Exit-aware: the first strand to
        peel off on a side sits outermost on that side; stayers fill the
        numeric middle. Single-direction bundles centre; mixed directions
        split around the centreline."""
        if slots:
            # chained sweep start where earlier lanes exist: extend outward
            for cid in present_journeys(si):
                k = key_of(cid)
                if k in slots:
                    continue
                gsign = group_sign(cid, si)
                slot_groups[k] = gsign
                # A leaver rejoining (or memory unusable): continue its own
                # prior ribbon — the nearest existing entry, converted into
                # this spine's frame — rather than a fresh lattice slot that
                # jumps the drawn lane at the record seam.
                own = (si if cid == jid else own_index(cid, si))
                if own is None and cid != jid:
                    own = nearest_own_index(cid, si)
                entry = (_nearest_entry(schedule, cid, own)
                         if own is not None else None)
                if entry is not None and not travels_far(cid, si):
                    d = seg_dir(si)
                    sign = (1 if entry.dx * d[0] + entry.dy * d[1] >= 0
                            else -1)
                    cand = entry.offset * sign
                    if all(abs(cand - v) >= SLOT_CLEARANCE
                           for v in occupied()):
                        slots[k] = cand
                        continue
                rank = _numeric_rank(geoms, present_journeys(si), cid, slots,
                                     key_of)
                side = join_side(cid, si)
                if side is None:
                    # See the cohort note: presence running to the sweep end
                    # is usually this strand peeling as the last partner.
                    out_si = next((b for a, b in presence[cid]
                                   if a <= si < b), s1)
                    side = exit_side(cid, min(out_si, s1))
                slots[k] = place(cid, side, gsign, rank, si=si)
                if DEBUG:
                    print(f"    [sweep {geoms[jid].num}] join {geoms[cid].num}"
                          f" side={side} gsign={gsign} rank={rank}"
                          f" -> offset {slots[k]:.2f}", file=sys.stderr)
            return
        cohort = []
        for cid in present_journeys(si):
            k = key_of(cid)
            if k in slots:
                continue
            gsign = group_sign(cid, si)
            out_si = next((b for a, b in presence[cid] if a <= si < b), s1)
            cohort.append((cid, k, gsign, out_si, None))
            slot_groups[k] = gsign
        with_group = [x for x in cohort if x[2] >= 0]
        against = [x for x in cohort if x[2] < 0]
        both = bool(with_group) and bool(against)

        def ordered(group, sign):
            """Fork walk, innermost -> outermost on this group's lattice.
            Departures are processed in street order; the first to leave on a
            side sits outermost there. Each side is measured against the
            members that REMAIN at the departure point: when the sweep spine
            itself peels off (transit center: every stayer "exits" where the
            longest run turns away, all at the same point, numerically
            tie-broken), single-polyline reference directions scramble the
            ladder."""
            # The spine itself always stays; any OTHER strand's presence
            # running to the sweep end is that strand leaving as the last
            # partner (the run ended because sharing ended), so it departs
            # at s1. Side=None continuation means it genuinely carries on
            # along the street -> stayer.
            stayers = [x for x in group if x[0] == jid]
            leaving = sorted(
                [x for x in group if x[0] != jid],
                key=lambda x: (min(x[3], s1), geoms[x[0]].sort_key()))
            lefts, rights = [], []   # outermost first
            for cid, k, gsign, out_si, _ in leaving:
                side = departure_side(cid, min(out_si, s1))
                if side == 1:
                    lefts.append((cid, k))
                elif side == -1:
                    rights.append((cid, k))
                else:
                    stayers.append((cid, k, gsign, out_si, None))
            middles = sorted(stayers,
                             key=lambda x: geoms[x[0]].sort_key())
            if DEBUG:
                print(f"      fork-walk s0={s0} s1={s1} jid={geoms[jid].num}")
                for cid, k, gsign, out_si, _ in leaving:
                    print(f"        leave {geoms[cid].num:>3} out_si={out_si}"
                          f" side={departure_side(cid, min(out_si, s1))}")
                for x in stayers:
                    print(f"        stay  {geoms[x[0]].num:>3}")
                seq_dbg = (rights if sign >= 0 else lefts) + middles
                seq_dbg += list(reversed(lefts if sign >= 0 else rights))
                print("        seq=" + str([geoms[x[0]].num for x in seq_dbg]))
            if sign >= 0:
                return rights + middles + list(reversed(lefts))
            return lefts + middles + list(reversed(rights))

        for group, sign in ((with_group, 1), (against, -1)):
            seq = ordered(group, sign)
            if not seq:
                continue
            if not both:
                n = len(seq)
                for i, x in enumerate(seq):
                    slots[x[1]] = (i - (n - 1) / 2) * LS * (1 if sign >= 0 else -1)
                continue
            slot = LS / 2 * sign
            for x in seq:
                slots[x[1]] = slot
                slot += LS * sign

    def record(bstart, bend, si_ref):
        present = present_journeys(si_ref)
        ref_keys = {key_of(c) for c in present}
        if sticky_ref[0] is None or key_of(sticky_ref[0]) not in ref_keys:
            sticky_ref[0] = present[0] if present else None
        ref_jid = sticky_ref[0]
        if ref_jid is None:
            return
        for si in range(bstart, bend):
            d = seg_dir(si)
            spine_slot = slots.get(key_of(jid))
            if spine_slot is not None and (jid, si) not in schedule:
                schedule[(jid, si)] = LaneSample(spine_slot, d[0], d[1], ref_jid)
            for cid in present:
                offset = slots.get(key_of(cid))
                if offset is None:
                    continue
                k = own_index(cid, si)
                if k is None:
                    continue
                if (cid, k) in schedule:
                    continue
                schedule[(cid, k)] = LaneSample(offset, d[0], d[1], ref_jid)

    bounds = {s0, s1}
    for stretches in presence.values():
        for a, b in stretches:
            if s0 <= a <= s1:
                bounds.add(a)
            if s0 <= b <= s1:
                bounds.add(b)
    bounds = sorted(bounds)

    prev = None
    for bi in range(len(bounds) - 1):
        bstart, bend = bounds[bi], bounds[bi + 1]
        if bend <= bstart:
            continue
        si = bstart
        adopt_existing(si)
        if prev is None:
            if DEBUG:
                print(f"    [sweep {geoms[jid].num}] birth at si={si}: "
                      f"{[geoms[c].num for c in present_journeys(si)]}",
                      file=sys.stderr)
            birth(si)
            if DEBUG:
                print(f"      slots: {{{', '.join(f'{k}: {v:.2f}' for k, v in slots.items())}}}",
                      file=sys.stderr)
        else:
            before = present_keys(prev)
            after = present_keys(si)
            for k in before:
                if k not in after and k in slots:
                    memory[k] = slots.pop(k)
                    slot_groups.pop(k, None)
            for cid in present_journeys(si):
                k = key_of(cid)
                if k in slots:
                    continue
                gsign = group_sign(cid, si)
                slot_groups[k] = gsign
                if k in memory and all(abs(memory[k] - v) >= SLOT_CLEARANCE
                                       for v in occupied()):
                    if not travels_far(cid, si):
                        slots[k] = memory[k]
                        continue
                    centre, width, n_stable = stable_bound(cid, si)
                    if n_stable == 1 or abs(memory[k] - (centre or 0.0)) <= width:
                        slots[k] = memory[k]
                        continue
                rank = _numeric_rank(geoms, present_journeys(si), cid, slots,
                                     key_of)
                side = join_side(cid, si)
                if side is None:
                    # A strand born on the corridor (trip start / boarding
                    # stop) appears in place, so any free slot is crossing
                    # free: prefer the side it will peel off toward, so a
                    # fork's strands sit adjacent, subway-style. Includes
                    # presence that runs to the sweep end (the spine's last
                    # partner peels there too).
                    out_si = next((b for a, b in presence[cid]
                                   if a <= si < b), s1)
                    side = exit_side(cid, min(out_si, s1))
                slots[k] = place(cid, side, gsign, rank, si=si)
                if DEBUG:
                    print(f"    [sweep {geoms[jid].num}] join {geoms[cid].num}"
                          f" side={side} gsign={gsign} rank={rank}"
                          f" -> offset {slots[k]:.2f}", file=sys.stderr)
        record(bstart, bend, si)
        prev = si


def _numeric_rank(geoms, present, cid, slots, key_of):
    """This journey's position among the still-unplaced joiners, by public
    identity order."""
    rank = 0
    for other in present:
        if other == cid:
            continue
        if key_of(other) in slots:
            continue
        if geoms[other].sort_key() < geoms[cid].sort_key():
            rank += 1
    return rank


def _nearest_entry(schedule, cid, si, window=12):
    for delta in range(0, window):
        for probe in (si - delta, si + delta):
            entry = schedule.get((cid, probe))
            if entry is not None:
                return entry
    return None


def _post_fill(geoms, scan, arcs, schedule):
    """Hold a lane through short schedule dropouts inside a journey's shared
    run (same distance and straightness gates as the shipped gap bridge)."""
    for jid, g in geoms.items():
        rows = scan[jid]
        n = len(rows)
        mm = mpm(g.coords[0][0])
        i = 0
        while i < n:
            if not rows[i]:
                i += 1
                continue
            j = i + 1
            while j < n and rows[j]:
                j += 1
            assigned = [s for s in range(i, j) if (jid, s) in schedule]
            for k in range(assigned[0] + 1, assigned[-1]) if len(assigned) >= 2 else []:
                if (jid, k) in schedule:
                    continue
                left = max(a for a in assigned if a < k)
                right = min(a for a in assigned if a > k)
                before, after = schedule[(jid, left)], schedule[(jid, right)]
                # hold the lane only when both anchors agree: a differing
                # right anchor is a genuine corridor change, not a dropout
                if (round(before.offset, 3) != round(after.offset, 3)
                        or before.ref_id != after.ref_id):
                    continue
                path = arcs[jid][k] - arcs[jid][left]
                chord = dist(g.points[left], g.points[k]) * mm
                if path <= GAP_BRIDGE and chord >= GAP_CHORD_RATIO * max(path, 1e-6):
                    schedule[(jid, k)] = before
            i = j
