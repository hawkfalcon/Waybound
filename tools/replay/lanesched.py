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
SIDE_LOOKAHEAD = 45.0      # metres of own geometry read for a join/exit side
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
        run_idxs = sorted(groups[root],
                          key=lambda i: -(arcs[runs[i][0]][runs[i][2]]
                                          - arcs[runs[i][0]][runs[i][1]]))
        memory = {}   # public key -> freed offset, for re-entry
        for run_idx in run_idxs:
            _sweep(geoms, scan, arcs, m, runs, run_idx, schedule, memory)
    _post_fill(geoms, scan, arcs, schedule)
    return schedule


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
        """Side cid leaves toward once its presence stretch ends."""
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
        fwd, travelled = k, 0.0
        while fwd < len(cg.points) - 1 and travelled < SIDE_LOOKAHEAD:
            travelled += dist(cg.points[fwd], cg.points[fwd + 1]) * mm
            fwd += 1
        seg = g.segs[probe]
        return _side_sign(cg.points[fwd], seg.s, seg_dir(probe), mm)

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

    def place(cid, side, gsign, numeric_rank):
        """Pick this joiner's slot: outside on its approach side, never
        crossing the centreline into the opposing direction group."""
        gofs = group_offsets(gsign)
        outward = 1 if gsign >= 0 else -1
        if not gofs:
            slots_for_group = LS / 2 * gsign
            if all(abs(slots_for_group - v) >= SLOT_CLEARANCE
                   for v in occupied()):
                return slots_for_group
            return free_slot(slots_for_group, LS / 2 * outward)
        if side is None:
            # The strand begins on the corridor (trip start / boarding stop):
            # prefer the slot its numeric identity suggests, else step outward.
            ordered = sorted(gofs)
            if numeric_rank >= len(ordered):
                target = outermost(gofs, outward) + LS * outward
            else:
                target = ordered[numeric_rank] if outward > 0 \
                    else list(reversed(ordered))[numeric_rank]
            if all(abs(target - v) >= SLOT_CLEARANCE for v in occupied()):
                return target
            return free_slot(target, LS / 2 * outward)
        if side == outward:
            base = outermost(gofs, outward) + LS * outward
            return free_slot(base, LS / 2 * outward)
        base = innermost(gofs, outward) - LS * outward
        if not crosses_centre(base, gsign):
            cand = free_slot(base, -LS / 2 * outward)
            if not crosses_centre(cand, gsign):
                return cand
        base = outermost(gofs, outward) + LS * outward
        return free_slot(base, LS / 2 * outward)

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
            slots[k] = entry.offset * sign
            slot_groups[k] = group_sign(cid, si)

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
                rank = _numeric_rank(geoms, present_journeys(si), cid, slots,
                                     key_of)
                side = join_side(cid, si)
                if side is None:
                    # A strand born on the corridor (trip start / boarding
                    # stop) appears in place, so any free slot is crossing
                    # free: prefer the side it will peel off toward, so a
                    # fork's strands sit adjacent, subway-style.
                    out_si = next((b for a, b in presence[cid]
                                   if a <= si < b), s1)
                    if out_si < s1:
                        side = exit_side(cid, out_si)
                slots[k] = place(cid, side, gsign, rank)
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
            stays = out_si >= s1
            side = None if stays else exit_side(cid, out_si)
            cohort.append((cid, k, gsign, out_si, side))
            slot_groups[k] = gsign
        with_group = [x for x in cohort if x[2] >= 0]
        against = [x for x in cohort if x[2] < 0]
        both = bool(with_group) and bool(against)

        def ordered(group, sign):
            # innermost -> outermost on this group's lattice
            lefts = sorted([x for x in group if x[4] == 1], key=lambda x: x[3])
            rights = sorted([x for x in group if x[4] == -1], key=lambda x: x[3])
            middles = sorted([x for x in group if x[4] is None],
                             key=lambda x: geoms[x[0]].sort_key())
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
                    slots[k] = memory[k]
                    continue
                rank = _numeric_rank(geoms, present_journeys(si), cid, slots,
                                     key_of)
                side = join_side(cid, si)
                if side is None:
                    # A strand born on the corridor (trip start / boarding
                    # stop) appears in place, so any free slot is crossing
                    # free: prefer the side it will peel off toward, so a
                    # fork's strands sit adjacent, subway-style.
                    out_si = next((b for a, b in presence[cid]
                                   if a <= si < b), s1)
                    if out_si < s1:
                        side = exit_side(cid, out_si)
                slots[k] = place(cid, side, gsign, rank)
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
