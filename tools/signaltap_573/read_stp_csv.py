#!/usr/bin/env python3
"""Validated decoder for Quartus 17.0 SignalTap CSV exports.

Format handled (Quartus Prime 17.0 "File > Export" CSV):
    Groups:
    <blank>
    Data:
    time unit: ns, <full|hierarchy|channel[0]>, <...channel[N]>,
    0, X, X, ..., X,
    1, 0, 1, ..., 0,
    ...

  - Header row: field 0 is "time unit: ns", fields 1..N are full hierarchy
    channel names, plus a trailing empty field (trailing comma).
  - Data rows: field 0 is the integer sample index, fields 1..N are channel
    values in {0,1,X}, plus a trailing empty field.
  - Storage-qualified captures contain all-X gap rows; the first row(s) may
    be all-X in any capture.

ALIGNMENT IS NEVER ASSUMED.  The header-name -> data-column mapping is
auto-calibrated per file: candidate shifts in -2..+2 are scored on
internal-consistency anchors (cell validity, one-hot FSM groups, 9-bit
bus value stability, sample-index monotonicity) and the evidence is
printed.  Pass --shift N to override.

NON-UNIFORM ALIGNMENT (Quartus 17.0 export_data_log quirk, observed
2026-06-09): when a channel is used as a trigger term, its DATA column can
be silently omitted from the CSV while its name stays in the header, and a
dead filler column appears later — every channel between the two points is
shifted by -1 relative to the header.  The `audit` command detects this via
independent consistency anchors and prints a suggested --map.  Use
    --map "1-10=0,11=none,12-66=-1,67=none,68-87=0"
to decode with a per-zone map (hdrRange=shift, or =none for channels whose
data is absent; unmapped channels default to the uniform shift).

Channel naming: channels are addressed by their short name (last hierarchy
segment, bit index stripped for buses).  When two scopes carry the same
short name (e.g. reqVRAMYPos exists at both igpu and igpu_pixelpipeline),
qualify with the owning instance: "igpu|reqVRAMYPos".

CLI examples:
    read_stp_csv.py FILE info
    read_stp_csv.py FILE hist textPalY textPalReqY
    read_stp_csv.py FILE dump --signals stage1_valid,textPalY --range 3580:3600
    read_stp_csv.py FILE edges pipeline_textPalNew --buses pipeline_textPalY,textPalY --window 5
    read_stp_csv.py FILE validate-a          # the file-A ground-truth gate
"""

import argparse
import sys
from collections import Counter, OrderedDict

X = "X"
SHIFT_RANGE = range(-2, 3)
AMBIGUITY_EPS = 0.02


# --------------------------------------------------------------------------
# parsing
# --------------------------------------------------------------------------

class Channel:
    __slots__ = ("hdr_idx", "full", "short", "owner", "base", "bit")

    def __init__(self, hdr_idx, full):
        self.hdr_idx = hdr_idx
        self.full = full
        segs = full.split("|")
        self.short = segs[-1]
        # owner = instance name of the innermost scope, e.g. "igpu" from
        # "gpu:igpu" or "igpu_pixelpipeline" from
        # "gpu_pixelpipeline:igpu_pixelpipeline".
        self.owner = segs[-2].split(":")[-1] if len(segs) >= 2 else ""
        if self.short.endswith("]") and "[" in self.short:
            b, _, idx = self.short[:-1].rpartition("[")
            try:
                self.bit = int(idx)
                self.base = b
            except ValueError:
                self.bit = None
                self.base = self.short
        else:
            self.bit = None
            self.base = self.short

    def __repr__(self):
        return f"<ch{self.hdr_idx} {self.owner}|{self.short}>"


def _parse_file(path):
    with open(path) as f:
        lines = f.read().splitlines()
    try:
        di = lines.index("Data:")
    except ValueError:
        sys.exit(f"error: no 'Data:' section in {path}")
    hdr_fields = [h.strip() for h in lines[di + 1].split(",")]
    if "time unit" not in hdr_fields[0]:
        sys.exit(f"error: unexpected header row (no 'time unit'): {hdr_fields[0]!r}")
    # channel names: everything after field 0 up to trailing empties
    names = list(hdr_fields[1:])
    while names and names[-1] == "":
        names.pop()
    channels = [Channel(i + 1, n) for i, n in enumerate(names)]

    rows = []  # (sample_idx, fields)  fields = raw split-stripped row
    for ln in lines[di + 2:]:
        if not ln.strip():
            continue
        fields = [x.strip() for x in ln.split(",")]
        try:
            si = int(fields[0])
        except ValueError:
            continue  # robustly drop any non-data row
        rows.append((si, fields))
    return channels, rows


# --------------------------------------------------------------------------
# capture object with shift-aware accessors
# --------------------------------------------------------------------------

def parse_map(spec, nch):
    """Parse '1-10=0,11=none,12-66=-1,...' into {hdr_idx: shift|None}."""
    out = {}
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        rng, _, val = part.partition("=")
        a, _, b = rng.partition("-")
        lo = int(a)
        hi = int(b) if b else lo
        sval = None if val.strip().lower() == "none" else int(val)
        for h in range(lo, hi + 1):
            if not 1 <= h <= nch:
                sys.exit(f"error: --map index {h} out of range 1..{nch}")
            out[h] = sval
    return out


class Capture:
    def __init__(self, path, shift=None, chmap=None, quiet=False):
        self.path = path
        self.channels, self.rows = _parse_file(path)
        self.n = len(self.rows)
        self.samples = [si for si, _ in self.rows]
        self.monotonic = all(b == a + 1 for a, b in zip(self.samples, self.samples[1:]))
        # bus registry: key (owner, base) -> {bit: channel}
        self.bus = {}
        self.scalars = {}
        for ch in self.channels:
            if ch.bit is not None:
                self.bus.setdefault((ch.owner, ch.base), {})[ch.bit] = ch
            else:
                self.scalars.setdefault((ch.owner, ch.base), ch)
        self.chmap = parse_map(chmap, len(self.channels)) if chmap else None
        self.shift, self.calib_report = self._calibrate(shift)
        if not quiet:
            print(self.calib_report)
            if self.chmap is not None:
                print(f"[map] per-channel map ACTIVE ({chmap}); uniform shift "
                      f"used only for unmapped channels")
        # all-X row mask (gap rows in storage-qualified captures)
        self.all_x = [all(v == X for v in self._vals(f)) for _, f in self.rows]

    # ---- raw cell access under a given shift -----------------------------
    def _cell(self, fields, hdr_idx, shift=None):
        if shift is None and self.chmap is not None and hdr_idx in self.chmap:
            s = self.chmap[hdr_idx]
            if s is None:
                return None  # channel has no data column in this export
        else:
            s = self.shift if shift is None else shift
        col = hdr_idx + s
        if 1 <= col < len(fields):
            return fields[col]
        return None  # mapped off the row (or onto the index column)

    def _vals(self, fields, shift=None):
        return [self._cell(fields, ch.hdr_idx, shift) for ch in self.channels]

    # ---- name resolution ---------------------------------------------------
    def _resolve(self, name, registry):
        if "|" in name:
            owner, _, base = name.rpartition("|")
            key = (owner, base)
            if key in registry:
                return key
            sys.exit(f"error: no signal '{name}' in {self.path}")
        cands = [k for k in registry if k[1] == name]
        if len(cands) == 1:
            return cands[0]
        if not cands:
            sys.exit(f"error: no signal '{name}'.  Known: "
                     + ", ".join(sorted({k[1] for k in registry})))
        sys.exit(f"error: '{name}' is ambiguous; qualify as one of: "
                 + ", ".join(f"{o}|{b}" for o, b in cands))

    def has_bus(self, name):
        return any(k[1] == name or f"{k[0]}|{k[1]}" == name for k in self.bus)

    def has_bit(self, name):
        return any(k[1] == name or f"{k[0]}|{k[1]}" == name for k in self.scalars)

    # ---- decoded series ----------------------------------------------------
    def bit_series(self, name, shift=None):
        key = self._resolve(name, self.scalars)
        ch = self.scalars[key]
        return [self._cell(f, ch.hdr_idx, shift) for _, f in self.rows]

    def bus_series(self, name, shift=None):
        """Decode a multi-bit bus; bits absent from the capture read as 0
        (e.g. drawMode is tapped only on bits [8:7])."""
        key = self._resolve(name, self.bus)
        bits = self.bus[key]
        out = []
        for _, f in self.rows:
            v = 0
            ok = True
            for b, ch in bits.items():
                cell = self._cell(f, ch.hdr_idx, shift)
                if cell == "1":
                    v |= 1 << b
                elif cell != "0":  # X, None, junk
                    ok = False
                    break
            out.append(v if ok else None)
        return out

    def series(self, name, shift=None):
        """bus or bit by name -> list of int|'0'/'1'|None."""
        try_bus = [k for k in self.bus if k[1] == name or f"{k[0]}|{k[1]}" == name]
        if try_bus:
            return self.bus_series(name, shift)
        return self.bit_series(name, shift)

    # ---- calibration ---------------------------------------------------------
    def _calibrate(self, forced):
        anchor_buses = [k for k in self.bus
                        if k[1] in ("textPalReqY", "textPalY", "pipeline_textPalY")]
        onehot_groups = {}
        for (owner, base), ch in self.scalars.items():
            if "." in base:  # FSM one-hot style: state.IDLE, vramState.READVRAM...
                onehot_groups.setdefault((owner, base.split(".")[0]), []).append(ch)
        onehot_groups = {k: v for k, v in onehot_groups.items() if len(v) >= 3}

        lines = [f"[calibration] {self.path}",
                 f"[calibration] {len(self.channels)} channels, {self.n} rows, "
                 f"sample idx {self.samples[0]}..{self.samples[-1]} "
                 f"monotonic={self.monotonic}"]
        ncols = len(self.rows[0][1]) if self.rows else 0
        # genuine value columns span [1 .. ncols-2]: col 0 is the sample
        # index, the last field is the trailing-comma empty.  Measured, not
        # assumed: verify the trailing field really is empty everywhere.
        trailing_empty = all(f[-1] == "" for _, f in self.rows)
        val_lo, val_hi = 1, (ncols - 2 if trailing_empty else ncols - 1)
        nvalcols = val_hi - val_lo + 1
        lines.append(f"[calibration] row fields={ncols} -> value cols "
                     f"{val_lo}..{val_hi} ({nvalcols}) for {len(self.channels)} "
                     f"channels; trailing-empty={trailing_empty}")
        scores = {}
        for s in SHIFT_RANGE:
            # 0. structural fit: channels must claim value columns bijectively;
            #    claiming the index column / trailing empty, or orphaning a
            #    value column, is structural evidence against the shift.
            claimed = {ch.hdr_idx + s for ch in self.channels}
            collisions = sum(1 for c in claimed if c < val_lo or c > val_hi)
            orphans = sum(1 for c in range(val_lo, val_hi + 1) if c not in claimed)
            structural = max(0.0, 1.0 - (collisions + orphans) / max(1, nvalcols))
            # 1. cell validity
            valid = total = 0
            for _, f in self.rows:
                for ch in self.channels:
                    cell = self._cell(f, ch.hdr_idx, s)
                    total += 1
                    if cell in ("0", "1", X):
                        valid += 1
            validity = valid / total if total else 0.0
            # 2. one-hot consistency (rows where the group is fully 0/1)
            oh_ok = oh_tot = 0
            for (owner, grp), chs in onehot_groups.items():
                for _, f in self.rows:
                    cells = [self._cell(f, c.hdr_idx, s) for c in chs]
                    if any(c not in ("0", "1") for c in cells):
                        continue
                    oh_tot += 1
                    if sum(c == "1" for c in cells) == 1:
                        oh_ok += 1
            onehot = oh_ok / oh_tot if oh_tot else 0.0
            # 3. bus stability: dominance of the modal value on anchor buses
            doms = []
            ndistinct = {}
            for k in anchor_buses:
                vals = [v for v in self.bus_series(f"{k[0]}|{k[1]}", shift=s)
                        if v is not None]
                if not vals:
                    continue
                cnt = Counter(vals)
                doms.append(cnt.most_common(1)[0][1] / len(vals))
                ndistinct[k[1]] = len(cnt)
            busdom = sum(doms) / len(doms) if doms else 0.0
            # Multiplicative: a structural collision (channel claiming the
            # sample-index column or the trailing empty) is fatal evidence,
            # not a 1% blemish.  Dominance of a constant bus saturates under
            # ANY shift of a constant, so it confirms but never adjudicates.
            score = (structural ** 4) * validity * onehot * (0.5 + 0.5 * busdom)
            scores[s] = score
            lines.append(
                f"[calibration]  shift={s:+d}: structural={structural:.4f} "
                f"(collisions={collisions} orphans={orphans}) "
                f"validity={validity:.4f} onehot={onehot:.4f} "
                f"busdom={busdom:.4f} distinct={ndistinct}  SCORE={score:.4f}")

        ranked = sorted(scores.items(), key=lambda kv: -kv[1])
        best, second = ranked[0], ranked[1]
        ambiguous = (best[1] - second[1]) < AMBIGUITY_EPS
        chosen = forced if forced is not None else best[0]
        tag = "FORCED" if forced is not None else "chosen"
        lines.append(f"[calibration] {tag} shift = {chosen:+d} "
                     f"(best {best[0]:+d}@{best[1]:.4f}, "
                     f"runner-up {second[0]:+d}@{second[1]:.4f})"
                     + ("  *** AMBIGUOUS (delta < %.2f) ***" % AMBIGUITY_EPS
                        if ambiguous and forced is None else ""))
        if ambiguous and forced is None:
            lines.append("[calibration] WARNING: top two shifts score close; "
                         "key-bus decode under BOTH shifts follows:")
            for k in anchor_buses:
                nm = f"{k[0]}|{k[1]}"
                for s in (best[0], second[0]):
                    vals = [v for v in self.bus_series(nm, shift=s) if v is not None]
                    cnt = Counter(vals).most_common(4)
                    lines.append(f"[calibration]   {k[1]} @shift{s:+d}: "
                                 f"top values {cnt}")
        return chosen, "\n".join(lines)


# --------------------------------------------------------------------------
# analyses
# --------------------------------------------------------------------------

def fmt_v(v):
    if v is None:
        return "X"
    return str(v)


def cmd_info(cap, args):
    print(f"file: {cap.path}")
    print(f"channels: {len(cap.channels)}  rows: {cap.n}  "
          f"all-X rows: {sum(cap.all_x)}  shift: {cap.shift:+d}")
    seen = set()
    for ch in cap.channels:
        key = (ch.owner, ch.base)
        if key in seen:
            continue
        seen.add(key)
        if ch.bit is not None:
            width = max(cap.bus[key]) + 1
            print(f"  bus  {ch.owner}|{ch.base}[{width-1}:0]")
        else:
            print(f"  bit  {ch.owner}|{ch.base}")


def cmd_hist(cap, args):
    for name in args.signals:
        vals = cap.series(name)
        cnt = Counter(v for v in vals if v is not None)
        nx = sum(1 for v in vals if v is None)
        print(f"histogram {name}  ({len(vals)} samples, {nx} X/undecodable):")
        for v, c in sorted(cnt.items(), key=lambda kv: -kv[1]):
            extra = ""
            if isinstance(v, int):
                extra = f" (0x{v:X})"
            print(f"  {v}{extra}: {c}")


def cmd_dump(cap, args):
    names = args.signals.split(",")
    series = {n: cap.series(n) for n in names}
    lo, hi = 0, cap.n
    if args.range:
        a, _, b = args.range.partition(":")
        lo = next((i for i, s in enumerate(cap.samples) if s >= int(a)), 0)
        hi = next((i for i, s in enumerate(cap.samples) if s > int(b)), cap.n)
    hdrs = ["sample"] + names
    print("\t".join(hdrs))
    for i in range(lo, hi):
        print("\t".join([str(cap.samples[i])] + [fmt_v(series[n][i]) for n in names]))


def rising_edges(bits):
    """indices i where bits[i]=='1' and bits[i-1]=='0'."""
    return [i for i in range(1, len(bits)) if bits[i] == "1" and bits[i - 1] == "0"]


def pulse_widths(bits, edges):
    out = []
    for e in edges:
        w = 0
        i = e
        while i < len(bits) and bits[i] == "1":
            w += 1
            i += 1
        out.append(w)
    return out


def cmd_edges(cap, args):
    bits = cap.bit_series(args.signal)
    edges = rising_edges(bits)
    widths = pulse_widths(bits, edges)
    high = sum(1 for b in bits if b == "1")
    print(f"signal {args.signal}: {len(edges)} rising edges, "
          f"{high} high samples / {len(bits)}")
    if edges:
        print(f"pulse widths: {dict(Counter(widths))}")
    buses = args.buses.split(",") if args.buses else []
    series = {n: cap.series(n) for n in buses}
    w = args.window
    shown = 0
    for e in edges:
        if shown >= args.max_events:
            print(f"... ({len(edges) - shown} more edges not shown)")
            break
        shown += 1
        print(f"\n-- rising edge at sample {cap.samples[e]} --")
        hdrs = ["sample", args.signal] + buses
        print("\t".join(hdrs))
        for i in range(max(0, e - w), min(cap.n, e + w + 1)):
            mark = " <-- edge" if i == e else ""
            print("\t".join([str(cap.samples[i]), bits[i] or "X"]
                            + [fmt_v(series[n][i]) for n in buses]) + mark)


def _runs_of(vals, hi="1"):
    runs = []
    start = None
    for i, v in enumerate(vals):
        if v == hi and start is None:
            start = i
        if v != hi and start is not None:
            runs.append(i - start)
            start = None
    if start is not None:
        runs.append(len(vals) - start)
    return runs


def cmd_audit(cap, args):
    """Detect NON-uniform header->column alignment (Quartus export drops the
    data column of trigger-term channels).  Each anchor independently votes
    for a LOCAL shift; disagreement between anchors in different header
    zones exposes a dropped column + filler column pair."""
    S = list(SHIFT_RANGE)
    votes = []  # (span_lo, span_hi, label, vote, margin, detail)

    def add_vote(lo, hi, label, scores, detail=""):
        ranked = sorted(scores.items(), key=lambda kv: -kv[1])
        vote, margin = None, 0.0
        if len(ranked) >= 2:
            margin = ranked[0][1] - ranked[1][1]
            if margin >= 0.05:
                vote = ranked[0][0]
        elif ranked:
            vote = ranked[0][0]
        votes.append((lo, hi, label, vote, margin, scores, detail))

    # -- anchor 1: structural (col 0 is the sample index; trailing field empty)
    # stage1-style first channel can only sit at col >= 1.
    first = cap.channels[0]
    add_vote(first.hdr_idx, first.hdr_idx, f"struct:{first.short}",
             {s: (1.0 if first.hdr_idx + s >= 1 else 0.0) for s in S},
             "first channel cannot map onto the sample-index column")

    # -- anchor 2: one-hot FSM groups: at-most-one-hot, penalize all-zero rows
    groups = {}
    for (owner, base), ch in cap.scalars.items():
        if "." in base:
            groups.setdefault((owner, base.split(".")[0]), []).append(ch)
    for (owner, grp), chs in sorted(groups.items(), key=lambda kv: kv[1][0].hdr_idx):
        if len(chs) < 3:
            continue
        chs = sorted(chs, key=lambda c: c.hdr_idx)
        scores = {}
        for s in S:
            ok = zero = tot = 0
            for _, f in cap.rows:
                cells = [cap._cell(f, c.hdr_idx, s) for c in chs]
                if any(c not in ("0", "1") for c in cells):
                    continue
                tot += 1
                n1 = sum(c == "1" for c in cells)
                ok += (n1 <= 1)
                zero += (n1 == 0)
            scores[s] = (ok / tot) * (1 - 0.5 * zero / tot) if tot else 0.0
        add_vote(chs[0].hdr_idx, chs[-1].hdr_idx, f"onehot:{grp}", scores)

    # -- anchor 3: pulse-shaped scalars (Req/New/wren/Done): expect short runs
    import re as _re
    for (owner, base), ch in sorted(cap.scalars.items(), key=lambda kv: kv[1].hdr_idx):
        if not _re.search(r"(Req$|New$|wren|Done$)", base):
            continue
        scores = {}
        for s in S:
            vals = [cap._cell(f, ch.hdr_idx, s) for _, f in cap.rows]
            ones = sum(v == "1" for v in vals)
            runs = _runs_of(vals)
            mx = max(runs) if runs else 0
            scores[s] = 1.0 if (0 < ones and mx <= 8) else (0.5 if ones == 0 else 0.0)
        add_vote(ch.hdr_idx, ch.hdr_idx, f"pulse:{base}", scores)

    # -- anchor 4: duplicate-name bus pairs gated by an Enable scalar
    dup = {}
    for (owner, base), bits in cap.bus.items():
        dup.setdefault(base, []).append((owner, bits))
    enables = [ch for (o, b), ch in cap.scalars.items() if b.endswith("Enable")]
    for base, insts in dup.items():
        if len(insts) != 2:
            continue
        (oA, bitsA), (oB, bitsB) = sorted(insts, key=lambda x: min(c.hdr_idx for c in x[1].values()))
        en = next((e for e in enables if e.owner == oB), enables[0] if enables else None)
        if en is None:
            continue
        best = (-1.0, None)
        table = {}
        for sE in S:
            gate = [i for i, (_, f) in enumerate(cap.rows)
                    if cap._cell(f, en.hdr_idx, sE) == "1"]
            if not gate:
                continue
            for sA in S:
                vA = cap.bus_series(f"{oA}|{base}", shift=sA)
                for sB in S:
                    vB = cap.bus_series(f"{oB}|{base}", shift=sB)
                    pairs = [(vA[i], vB[i]) for i in gate
                             if vA[i] is not None and vB[i] is not None]
                    if not pairs:
                        continue
                    eq = sum(a == b for a, b in pairs) / len(pairs)
                    table[(sA, sB, sE)] = (eq, len(pairs))
                    if eq > best[0]:
                        best = (eq, (sA, sB, sE))
        if best[1] is None:
            continue
        sA, sB, sE = best[1]
        eq, npairs = table[best[1]]
        loA = min(c.hdr_idx for c in bitsA.values()); hiA = max(c.hdr_idx for c in bitsA.values())
        loB = min(c.hdr_idx for c in bitsB.values()); hiB = max(c.hdr_idx for c in bitsB.values())
        det = (f"best ({oA}@{sA:+d}, {oB}@{sB:+d}, {en.base}@{sE:+d}): "
               f"eq={eq:.2f} over {npairs} gated cycles")
        add_vote(loA, hiA, f"dupbusA:{oA}|{base}",
                 {s: (table.get((s, sB, sE), (0, 0))[0]) for s in S}, det)
        add_vote(loB, hiB, f"dupbusB:{oB}|{base}",
                 {s: (table.get((sA, s, sE), (0, 0))[0]) for s in S}, det)
        add_vote(en.hdr_idx, en.hdr_idx, f"dupbusEn:{en.base}",
                 {s: (table.get((sA, sB, s), (0, 0))[0]) for s in S}, det)

        # -- anchor 5 (semantic): palette-fetch equality — at gated cycles the
        # gpu-side YPos sometimes equals textPalReqY (a CLUT row fetch).
        req = [k for k in cap.bus if k[1] == "textPalReqY"]
        if req and base == "reqVRAMYPos":
            k = req[0]
            lo = min(c.hdr_idx for c in cap.bus[k].values())
            hi = max(c.hdr_idx for c in cap.bus[k].values())
            vB = cap.bus_series(f"{oB}|{base}", shift=sB)
            gate = [i for i, (_, f) in enumerate(cap.rows)
                    if cap._cell(f, en.hdr_idx, sE) == "1"]
            scores = {}
            for s in S:
                vR = cap.bus_series(f"{k[0]}|{k[1]}", shift=s)
                m = sum(1 for i in gate if vR[i] is not None and vR[i] == vB[i])
                scores[s] = min(1.0, m)  # any match at all is the signal
            add_vote(lo, hi, "palfetch:textPalReqY==gpuY", scores,
                     f"matches per shift: { {s: int(scores[s]) for s in S} }")

    # -- anchor 6 (semantic): pipeline_busy must cover stage1_valid activity
    sv = next((ch for (o, b), ch in cap.scalars.items() if b == "stage1_valid"), None)
    busy = next((ch for (o, b), ch in cap.scalars.items() if b == "pipeline_busy"), None)
    if sv is not None and busy is not None:
        svv = [cap._cell(f, sv.hdr_idx, 0) for _, f in cap.rows]
        act = [i for i, v in enumerate(svv) if v == "1"]
        if act:
            scores = {}
            for s in S:
                bv = [cap._cell(cap.rows[i][1], busy.hdr_idx, s) for i in act]
                scores[s] = sum(v == "1" for v in bv) / len(act)
            add_vote(busy.hdr_idx, busy.hdr_idx, "imply:busy>=stage1_valid", scores)

    # ---- report ----
    print(f"[audit] {cap.path}")
    print(f"[audit] {'anchor':34s} span        vote   margin  scores")
    for lo, hi, label, vote, margin, scores, det in sorted(votes, key=lambda v: (v[0], v[1])):
        sc = " ".join(f"{s:+d}:{scores[s]:.2f}" for s in S)
        v = f"{vote:+d}" if vote is not None else "  -"
        print(f"[audit] {label:34s} hdr{lo:3d}-{hi:3d}  {v}   {margin:.3f}   {sc}"
              + (f"   [{det}]" if det else ""))

    # zone fit from decisive votes.  Model (matches the observed Quartus
    # quirk): data columns are consumed in header order starting ALIGNED
    # (hdr1 <-> col1); a DROPPED channel decrements the local shift by 1, a
    # dead FILLER column increments it back.  So the shift sequence starts
    # at 0 by construction.
    dec = [(lo, hi, label, vote) for lo, hi, label, vote, m, s, d
           in sorted(votes, key=lambda v: (v[0], v[1])) if vote is not None]
    zones = [(0, 0, 0)]  # synthetic structural start: shift 0 before hdr1
    for lo, hi, label, vote in dec:
        if zones[-1][2] == vote:
            zones[-1] = (zones[-1][0], hi, vote)
        else:
            zones.append((lo, hi, vote))
    print("[audit] decisive-vote zones (header ranges with agreed local shift; "
          "hdr0 = structural start):")
    for lo, hi, vote in zones:
        print(f"[audit]   hdr {lo:3d}..{hi:3d}: shift {vote:+d}")
    if len(set(z[2] for z in zones)) <= 1:
        print("[audit] VERDICT: alignment is UNIFORM (no export anomaly detected).")
        return
    print("[audit] VERDICT: NON-UNIFORM alignment — the export dropped/added "
          "column(s); channels between a drop and the next filler are shifted.")
    nch = len(cap.channels)
    ncols = len(self_fields := cap.rows[0][1]) if cap.rows else 0
    # column ones-count for dead-column checks
    col_ones = {c: sum(1 for _, f in cap.rows if f[c] == "1") for c in range(1, nch + 1)}
    parts = []
    cur = 1
    cur_shift = 0
    for i in range(len(zones) - 1):
        a, b = zones[i], zones[i + 1]
        gap_lo, gap_hi = a[1], b[0]
        if b[2] == a[2] - 1:  # DROP: one channel in (gap_lo..gap_hi] has no column
            bp = None
            if args.trigger_ch:
                tc = [ch for ch in cap.channels
                      if ch.short == args.trigger_ch or ch.base == args.trigger_ch]
                if tc and gap_lo < tc[0].hdr_idx <= gap_hi:
                    bp = tc[0].hdr_idx
                    print(f"[audit]   DROPPED channel in hdr ({gap_lo}..{gap_hi}] "
                          f"-> pinned to hdr {bp} ('{args.trigger_ch}'): a "
                          f"trigger-term channel provably pulsed, yet no candidate "
                          f"column shows it, so its data column is the missing one")
            if bp is None:
                bp = gap_hi
                print(f"[audit]   DROPPED channel in hdr ({gap_lo}..{gap_hi}] "
                      f"(exact position ambiguous; decodes of channels outside "
                      f"the interval are unaffected — using hdr {bp})")
            if cur <= bp - 1:
                parts.append(f"{cur}-{bp-1}={cur_shift:+d}")
            parts.append(f"{bp}=none")
            cur = bp + 1
            cur_shift = b[2]
        elif b[2] == a[2] + 1:  # FILLER: one dead column appears in the gap
            # candidate first-realigned-channel F in (gap_lo+1 .. gap_hi]:
            # unclaimed column is F-1+a_shift... under shifts (-1 -> 0) the
            # skipped column index is F-1.  It must be DEAD (no ones).
            cands = [F for F in range(gap_lo + 1, gap_hi + 1)
                     if col_ones.get(F - 1, 0) == 0]
            if not cands:
                cands = [gap_hi]
            Fmin, Fmax = cands[0], cands[-1]
            # channels h < Fmin keep the old shift under every candidate;
            # h >= Fmax are realigned under every candidate; only
            # h in [Fmin, Fmax-1] get a different (dead) column per candidate.
            amb = list(range(Fmin, Fmax))
            print(f"[audit]   FILLER column in hdr ({gap_lo}..{gap_hi}]: dead-column "
                  f"check leaves realign candidates F={cands}; ambiguous channels "
                  f"hdr {amb} (their candidate columns are all dead -> value 0/X "
                  f"either way, marked =none)")
            if cur <= Fmin - 1:
                parts.append(f"{cur}-{Fmin-1}={cur_shift:+d}")
            for h in amb:
                parts.append(f"{h}=none")
            cur = Fmax
            cur_shift = b[2]
        else:
            print(f"[audit]   WARNING: shift jump {a[2]:+d} -> {b[2]:+d} between "
                  f"hdr {gap_lo} and {gap_hi} is not a single drop/filler; "
                  f"map suggestion unreliable here")
            cur_shift = b[2]
    if cur <= nch:
        parts.append(f"{cur}-{nch}={cur_shift:+d}")
    print(f"[audit] SUGGESTED --map \"{','.join(parts)}\"")
    print("[audit] (channels marked =none are unobservable in this export; "
          "re-export or re-capture to recover them)")


def cmd_validate_a(cap, args):
    """Ground-truth gate for capture A (clut_race_20260609_213217.csv):
    stage1_valid=1 rows == 513; textPalReqY==480, textPalY==480,
    drawMode[8:7]==00 at every one of them."""
    sv = cap.bit_series("stage1_valid")
    reqy = cap.bus_series("textPalReqY")
    paly = cap.bus_series("textPalY")
    # drawMode is tapped only on bits [8:7]; decoded value must be 0
    dm = cap.bus_series("drawMode") if cap.has_bus("drawMode") else None

    rows = [i for i, v in enumerate(sv) if v == "1"]
    okc = len(rows) == 513
    print(f"gate 1: stage1_valid=1 rows = {len(rows)} (expect 513): "
          f"{'PASS' if okc else 'FAIL'}")
    bad_req = [i for i in rows if reqy[i] != 480]
    bad_pal = [i for i in rows if paly[i] != 480]
    print(f"gate 2: textPalReqY==480 at all of them: "
          f"{'PASS' if not bad_req else f'FAIL ({len(bad_req)} bad)'}")
    print(f"gate 3: textPalY==480 at all of them: "
          f"{'PASS' if not bad_pal else f'FAIL ({len(bad_pal)} bad)'}")
    if dm is not None:
        # drawMode bus only carries bits 7,8 in this instance; value must be 0
        bad_dm = [i for i in rows if dm[i] != 0]
        print(f"gate 4: drawMode[8:7]==00 at all of them: "
              f"{'PASS' if not bad_dm else f'FAIL ({len(bad_dm)} bad)'}")
    else:
        bad_dm = []
        print("gate 4: drawMode bits not found: FAIL")
    allok = okc and not bad_req and not bad_pal and dm is not None and not bad_dm
    print(f"VALIDATION GATE: {'PASS' if allok else 'FAIL'}")
    return 0 if allok else 1


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("--shift", type=int, default=None,
                    help="force the header->data column shift (skip auto-calibration choice)")
    ap.add_argument("--map", dest="chmap", default=None,
                    help='per-channel map, e.g. "1-10=0,11=none,12-66=-1,67=none,68-87=0"')
    ap.add_argument("--quiet-calib", action="store_true",
                    help="suppress the calibration evidence printout")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("info")

    p = sub.add_parser("audit")
    p.add_argument("--trigger-ch", default=None,
                   help="short name of the trigger-term channel (known to have "
                        "pulsed); pins the dropped-column position")

    p = sub.add_parser("hist")
    p.add_argument("signals", nargs="+")

    p = sub.add_parser("dump")
    p.add_argument("--signals", required=True, help="comma-separated names")
    p.add_argument("--range", default=None, help="sample range lo:hi (inclusive)")

    p = sub.add_parser("edges")
    p.add_argument("signal")
    p.add_argument("--buses", default="", help="comma-separated companion signals")
    p.add_argument("--window", type=int, default=5)
    p.add_argument("--max-events", type=int, default=6)

    sub.add_parser("validate-a")

    args = ap.parse_args()
    cap = Capture(args.file, shift=args.shift, chmap=args.chmap,
                  quiet=args.quiet_calib)
    rc = 0
    if args.cmd == "info":
        cmd_info(cap, args)
    elif args.cmd == "audit":
        cmd_audit(cap, args)
    elif args.cmd == "hist":
        cmd_hist(cap, args)
    elif args.cmd == "dump":
        cmd_dump(cap, args)
    elif args.cmd == "edges":
        cmd_edges(cap, args)
    elif args.cmd == "validate-a":
        rc = cmd_validate_a(cap, args)
    sys.exit(rc)


if __name__ == "__main__":
    main()
