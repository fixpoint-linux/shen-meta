#!/usr/bin/env python3
"""extract.py — parse globals.qbe (QBE IR for the Shen native closures) into
Soufflé fact CSVs for GC-root-safety analysis.

The QBE backend (shen/qbe.shen) lowers each bundled closure to a QBE function
`function $clo_X(l %out, l %a0, ...)`. Every Value temp is a native-stack slot:

    %tN =l alloc8 40        ; a 40-byte Value slot (sizeof(Value)==40)
    %cN =w call $is_false(l %tN)      ; pure word test (non-collecting)
    call $prim_* (l %tN, ...)         ; C primitive, result -> first l arg
    call $clo_*  (l %tN, ...)         ; native closure, result -> first l arg
    call $val_*_into(l %tN, ...)      ; materialize a Value -> first l arg
    call $copy_value(l %tN, l %tM)    ; copy a Value -> first l arg
    call $trap_<n>_<m>(...)           ; defunctionalized trap shim
    %tN =l phi @bA %tX, @bB %tY       ; phi join

We extract the facts the Datalog rules need. Emits to facts/ (CSV, headers).

Usage: extract.py [globals.qbe]   (default: ../../globals.qbe)
"""
import re, os, sys, csv

QBE = sys.argv[1] if len(sys.argv) > 1 else "../../globals.qbe"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "facts")
os.makedirs(OUT, exist_ok=True)

# Each fact row: (function, sid, ...).  sid = statement sequence within a
# function (0-based over the body lines we care about), for ordering.
facts = {
    "function": [],      # function(f)
    "stmt": [],          # stmt(f, sid)
    "alloc": [],         # alloc(f, sid, temp)   -- local Value slot
    "call": [],          # call(f, sid, callee)
    "call_out": [],      # call_out(f, sid, temp) -- producing call's out slot
    "call_arg": [],      # call_arg(f, sid, temp) -- any l temp used as an arg
    "phi_out": [],       # phi_out(f, sid, temp)
    "phi_in": [],        # phi_in(f, sid, temp)
    "pushed": [],        # pushed(f, t) -- gc_root_push_value(l %tN) fact
}

# Callees that WRITE a GC-managed Value into their first `l` arg (the out).
def is_producing(callee):
    return (callee.startswith("prim_") or callee.startswith("clo_") or
            callee.startswith("trap_") or callee.startswith("val_") or
            callee == "copy_value")

def l_temps(args_str):
    # args like "l %t0, l %a0, w 1" -> ["%t0", "%a0"] (l-typed only)
    out = []
    for a in args_str.split(","):
        a = a.strip()
        if a.startswith("l %"):
            out.append(a[2:])  # "%tN"
    return out

fn = None
sid = 0
# Match both `function $clo_<name>(...)` (native closures) and
# `function $b_<tag>(...)` (defunctionalized cur bodies emitted by
# qbe-lower-cur).  Cur-body tags are integers; prefix the f-symbol with
# "b_" so they cannot collide with any clo_ name (clo names are mangled
# via qbe-ident and never start with "b_" followed by a digit).
func_re  = re.compile(r"^function \$(?P<kind>clo_|b_)(?P<name>[A-Za-z0-9_.]+)\((?P<args>[^)]*)\) \{$")
call_re  = re.compile(r"^call \$(?P<callee>[A-Za-z0-9_.]+)\((?P<args>[^)]*)\)$")
wc_re    = re.compile(r"^%\w+ =w call \$(?P<callee>[A-Za-z0-9_.]+)\((?P<args>[^)]*)\)$")
alloc_re = re.compile(r"^%(\w+) =l alloc8 40$")
phi_re   = re.compile(r"^%(\w+) =l phi (?P<ins>.*)$")
# `call $gc_root_push_value(l %tN)` — the per-frame rooting prologue emitted by
# qbe-inject-allocs.  We record pushed(f, t) so the Datalog root_miss rule can
# suppress live slots that ARE rooted for the whole frame lifetime.
push_re  = re.compile(r"^call \$gc_root_push_value\(l (?P<t>%\w+)\)$")

with open(QBE) as f:
    for raw in f:
        line = raw.rstrip("\n").strip()
        if not line or line == "export":
            continue
        m = func_re.match(line)
        if m:
            # clo_<name>  -> f = name ;  b_<tag>  -> f = "b_" + tag (distinct)
            fn = m.group("name") if m.group("kind") == "clo_" else "b_" + m.group("name")
            sid = 0
            continue
        if line.startswith("@b"):
            continue  # block label
        if line in ("ret",):
            if fn is not None:
                sid += 1
            continue
        if fn is None:
            continue
        # --- alloc ---
        m = alloc_re.match(line)
        if m:
            facts["function"].append([fn])
            facts["stmt"].append([fn, sid])
            facts["alloc"].append([fn, sid, "%" + m.group(1)])
            sid += 1
            continue
        # --- phi ---
        m = phi_re.match(line)
        if m:
            facts["function"].append([fn])
            facts["stmt"].append([fn, sid])
            facts["phi_out"].append([fn, sid, "%" + m.group(1)])
            for ins in m.group("ins").split(","):
                ins = ins.strip()
                # "@b3 %t1"
                if " " in ins:
                    facts["phi_in"].append([fn, sid, ins.split()[-1]])
            sid += 1
            continue
        # --- w call (is_false etc) ---
        m = wc_re.match(line)
        if m:
            callee, args = m.group("callee"), m.group("args")
            facts["function"].append([fn])
            facts["stmt"].append([fn, sid])
            facts["call"].append([fn, sid, callee])
            for t in l_temps(args):
                facts["call_arg"].append([fn, sid, t])
            sid += 1
            continue
        # --- plain call ---
        m = call_re.match(line)
        if m:
            callee, args = m.group("callee"), m.group("args")
            ls = l_temps(args)
            # Per-frame rooting prologue/epilogue: `call $gc_root_push_value(l %tN)`
            # records %tN as a pushed ROOT_VALUE for this frame lifetime.  The
            # rooting helpers (val_nil_into / gc_root_push_value /
            # gc_root_watermark / gc_root_pop_to) do NOT trigger GC and are
            # not interesting for liveness, so we do NOT emit stmt/call/call_arg
            # facts for them — only the `pushed` fact.  This keeps the fact
            # count (and the Datalog's O(stmts²) read_after/defined_before
            # cross-products) close to the pre-rooting baseline, so the
            # verifier stays tractable.
            if callee == "gc_root_push_value" and ls:
                facts["pushed"].append([fn, ls[0]])
            if callee in ("val_nil_into", "gc_root_push_value",
                          "gc_root_watermark", "gc_root_pop_to"):
                # rooting helper: no stmt/call/call_arg/call_out facts
                continue
            facts["function"].append([fn])
            facts["stmt"].append([fn, sid])
            facts["call"].append([fn, sid, callee])
            if ls and is_producing(callee):
                facts["call_out"].append([fn, sid, ls[0]])
            for t in ls:
                facts["call_arg"].append([fn, sid, t])
            sid += 1
            continue
        # jnz / jmp / anything else: advance sid (still orders the stream)
        if line.startswith("jnz") or line.startswith("jmp"):
            sid += 1
            continue

# Write CSVs (dedup, headers)
headers = {
    "function": "f",
    "stmt": "f,sid",
    "alloc": "f,sid,t",
    "call": "f,sid,callee",
    "call_out": "f,sid,t",
    "call_arg": "f,sid,t",
    "phi_out": "f,sid,t",
    "phi_in": "f,sid,t",
    "pushed": "f,t",
}
for name, rows in facts.items():
    seen = set()
    uniq = []
    for r in rows:
        k = tuple(r)
        if k not in seen:
            seen.add(k)
            uniq.append(r)
    with open(os.path.join(OUT, name + ".csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(headers[name].split(","))
        for r in sorted(uniq):
            w.writerow(r)
    print(f"{name}.csv: {len(uniq)} rows")
