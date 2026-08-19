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
func_re  = re.compile(r"^function \$clo_(?P<name>[A-Za-z0-9_.]+)\((?P<args>[^)]*)\) \{$")
call_re  = re.compile(r"^call \$(?P<callee>[A-Za-z0-9_.]+)\((?P<args>[^)]*)\)$")
wc_re    = re.compile(r"^%\w+ =w call \$(?P<callee>[A-Za-z0-9_.]+)\((?P<args>[^)]*)\)$")
alloc_re = re.compile(r"^%(\w+) =l alloc8 40$")
phi_re   = re.compile(r"^%(\w+) =l phi (?P<ins>.*)$")

with open(QBE) as f:
    for raw in f:
        line = raw.rstrip("\n").strip()
        if not line or line == "export":
            continue
        m = func_re.match(line)
        if m:
            fn = m.group("name")
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
            facts["function"].append([fn])
            facts["stmt"].append([fn, sid])
            facts["call"].append([fn, sid, callee])
            ls = l_temps(args)
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
