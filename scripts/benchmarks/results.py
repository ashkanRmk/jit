#!/usr/bin/env python3
"""Phase 6 benchmark results (ADR-0041): normalizes scenario output lines into the versioned results JSON,
writes the Markdown summary, and compares two results files with per-metric thresholds.

  results.py collect <out.json> <summary.md> <lines.txt> [micro.json]   # run-all.sh
  results.py compare <baseline.json> <candidate.json> [--loose]          # exit 1 on regression
"""
import datetime, json, platform, re, subprocess, sys

SCHEMA = 1

def sh(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return ""

def machine():
    power = sh("pmset", "-g", "batt")
    return {
        "model": sh("sysctl", "-n", "hw.model"),
        "chip": sh("sysctl", "-n", "machdep.cpu.brand_string"),
        "ram_gb": round(int(sh("sysctl", "-n", "hw.memsize") or 0) / 2**30),
        "macos": platform.mac_ver()[0],
        "macos_build": sh("sw_vers", "-buildVersion"),
        "power_source": "ac" if "AC Power" in power else ("battery" if power else "unknown"),
        "low_power_mode": "lowpowermode 1" in sh("pmset", "-g").replace("\t", " ").lower(),
        "thermal": sh("pmset", "-g", "therm").splitlines()[-1:] or [],
    }

GRAPH = {
    # GraphBenchmark lines (graph-scroll scenario).
    r"graph_first_rows_ms=([\d.]+)": ("graph.firstRows", "ms"),
    r"graph_scroll_step_ms median=([\d.]+) p95=([\d.]+) max=([\d.]+) n=(\d+) over_16ms=(\d+)": ("scroll_step", "ms"),
    r"graph_row_draw_ms median=([\d.]+) p95=([\d.]+) max=([\d.]+) n=(\d+)": ("row_draw", "ms"),
    r"graph_page_append_ms median=([\d.]+) p95=([\d.]+) max=([\d.]+) n=(\d+)": ("page_append", "ms"),
    r"graph_footprint_all_loaded_mb=([\d.]+)": ("footprint_all_loaded", "MB"),
}

def parse(lines):
    scenarios, errors = {}, []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        m = re.match(r"scenario=(\S+) (.*)", line)
        if m:
            name, rest = m.groups()
            fields = dict(kv.split("=", 1) for kv in rest.split() if "=" in kv)
            if "error" in fields:
                errors.append({"scenario": name, **fields})
                continue
            metric = fields.pop("metric")
            entry = {"unit": fields.pop("unit", "")}
            if "median" in fields:
                entry.update(median=float(fields["median"]), p90=float(fields["p90"]), runs=int(fields.get("n", 0)))
                if "max" in fields: entry["max"] = float(fields["max"])
            elif "value" in fields:
                entry.update(median=float(fields["value"]), p90=float(fields.get("max", fields["value"])), runs=1)
            else:  # footprint loop: first/after10/last/settled
                for key in ("first", "after10", "last", "settled"):
                    if key in fields:
                        scenarios.setdefault(name, {})[f"{metric}.{key}"] = {"median": float(fields[key]), "p90": float(fields[key]), "unit": entry["unit"], "runs": 1}
                continue
            if fields.get("triggers"): entry["triggers"] = fields["triggers"]
            scenarios.setdefault(name, {})[metric] = entry
            continue
        for pattern, (metric, unit) in GRAPH.items():
            g = re.search(pattern, line)
            if g:
                values = [float(x) for x in g.groups()]
                entry = {"median": values[0], "p90": values[1] if len(values) > 1 else values[0], "unit": unit,
                         "runs": int(values[3]) if len(values) > 3 else 1}
                if len(values) > 4: entry["over_16ms"] = int(values[4])
                scenarios.setdefault("graph-scroll", {})[metric] = entry
    return scenarios, errors

def collect(out, summary, lines_path, micro=None):
    scenarios, errors = parse(open(lines_path).read().splitlines())
    if micro:
        try: scenarios.update(json.load(open(micro))["scenarios"])
        except FileNotFoundError: errors.append({"scenario": "micro", "error": "missing"})
    result = {
        "schema": SCHEMA,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "git_sha": sh("git", "rev-parse", "--short", "HEAD"),
        "machine": machine(),
        "git_version": sh("git", "--version"),
        "build": "release",
        "scenarios": scenarios,
        "errors": errors,
    }
    json.dump(result, open(out, "w"), indent=2, sort_keys=True)
    with open(summary, "w") as f:
        m = result["machine"]
        f.write(f"# Benchmark run {result['timestamp']} ({result['git_sha']})\n\n")
        f.write(f"{m['model']} ({m['chip']}, {m['ram_gb']} GB), macOS {m['macos']} ({m['macos_build']}), "
                f"{result['git_version']}, power {m['power_source']}, Low Power Mode {'on' if m['low_power_mode'] else 'off'}\n\n")
        f.write("| Scenario | Metric | Median | p90 | Unit | Runs |\n|---|---|---|---|---|---|\n")
        for name in sorted(scenarios):
            for metric, e in sorted(scenarios[name].items()):
                f.write(f"| {name} | {metric} | {e['median']:.3f} | {e['p90']:.3f} | {e['unit']} | {e['runs']} |\n")
        if errors:
            f.write("\n## Not measured / errors\n\n")
            for e in errors:
                f.write(f"- {e}\n")
    print(open(summary).read())

# Thresholds (ADR-0041): relative for times/memory, absolute for idle CPU and wakeups.
def threshold(metric, unit, loose):
    factor = 2.5 if loose else 1.0
    if unit == "%":
        return ("abs", 0.1 * factor)
    if unit == "1/s":
        return ("abs", 1.0 * factor)
    if unit == "MB":
        return ("rel", 0.10 * factor)
    if unit == "count":
        return ("abs", 2 * factor)
    if unit == "ms/s":
        return ("abs", 2.0 * factor)   # idle CPU: 2 ms/s = 0.2 % of one core
    if unit == "energy":
        return ("abs", 0.5 * factor)
    if unit == "bytes":
        return ("abs", 0)               # idle network must stay zero
    return ("rel", 0.10 * factor)  # ms: launch +10 %, etc.

def compare(base_path, cand_path, loose=False):
    base, cand = json.load(open(base_path)), json.load(open(cand_path))
    rows, regressions, missing = [], 0, 0
    for name, metrics in sorted(base["scenarios"].items()):
        for metric, b in sorted(metrics.items()):
            if b.get("unit") == "info":
                continue  # informational only (e.g. top's IDLEW, ADR-0041)
            c = cand.get("scenarios", {}).get(name, {}).get(metric)
            if c is None:
                rows.append((name, metric, b["median"], None, "MISSING")); missing += 1; continue
            kind, limit = threshold(metric, b.get("unit", ""), loose)
            # Small absolute floor for tiny timings (sub-millisecond noise).
            delta = c["median"] - b["median"]
            if kind == "rel":
                allowed = max(abs(b["median"]) * limit, 0.05 if b.get("unit") == "ms" else 0)
            else:
                allowed = limit
            status = "REGRESSION" if delta > allowed else "ok"
            if status == "REGRESSION": regressions += 1
            rows.append((name, metric, b["median"], c["median"], status))
    width = max(len(f"{r[0]}/{r[1]}") for r in rows) if rows else 10
    for name, metric, b, c, status in rows:
        cs = "—" if c is None else f"{c:.3f}"
        print(f"{name + '/' + metric:<{width}}  {b:>10.3f} → {cs:>10}  {status}")
    print(f"\n{regressions} regression(s), {missing} missing metric(s)")
    return 1 if regressions or missing else 0

if __name__ == "__main__":
    if len(sys.argv) >= 5 and sys.argv[1] == "collect":
        collect(*sys.argv[2:6])
    elif len(sys.argv) >= 4 and sys.argv[1] == "compare":
        sys.exit(compare(sys.argv[2], sys.argv[3], "--loose" in sys.argv))
    else:
        print(__doc__); sys.exit(2)
