#!/usr/bin/env python3
"""Extracts Jit's signpost intervals (subsystem com.ashkanrmk.jit) from an xctrace recording.

  signposts.py <file.trace>      → JSON {interval: {count, median_ms, p90_ms, max_ms}} on stdout

Uses `xctrace export --xpath` on the os-signpost table and resolves its id/ref deduplication.
Verified with Xcode 27.2 (xctrace 27.2); the table schema may change across Xcode versions (ADR-0041).
"""
import json, statistics, subprocess, sys
import xml.etree.ElementTree as ET

SUBSYSTEM = "com.ashkanrmk.jit"

def export(trace):
    xpath = '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]'
    return subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xpath],
                          capture_output=True, text=True, check=True).stdout

def rows(xml_text):
    root = ET.fromstring(xml_text)
    ids = {}
    for element in root.iter():
        if "id" in element.attrib:
            ids[element.attrib["id"]] = element
    def resolve(element):
        return ids.get(element.attrib["ref"], element) if "ref" in element.attrib else element
    for row in root.iter("row"):
        cells = [resolve(c) for c in row]
        record = {}
        for cell in cells:
            tag = cell.tag
            if tag == "event-time": record["time"] = int(cell.text)
            elif tag == "event-type": record["type"] = cell.text
            elif tag == "signpost-name": record["name"] = cell.text
            elif tag == "subsystem": record["subsystem"] = cell.text
            elif tag == "os-signpost-identifier": record["id"] = cell.text
        yield record

def intervals(trace):
    open_, done, seen = {}, {}, set()
    for r in rows(export(trace)):
        if r.get("subsystem") != SUBSYSTEM or "name" not in r:
            continue
        # The export holds the same event once per os-signpost table (Points of Interest, unfiltered, …).
        identity = (r.get("time"), r.get("type"), r["name"], r.get("id"))
        if identity in seen:
            continue
        seen.add(identity)
        key = (r["name"], r.get("id"))
        if r.get("type") == "Begin":
            open_[key] = r["time"]
        elif r.get("type") == "End" and key in open_:
            done.setdefault(r["name"], []).append((r["time"] - open_.pop(key)) / 1e6)
    out = {}
    for name, values in sorted(done.items()):
        values.sort()
        out[name] = {"count": len(values), "median_ms": round(statistics.median(values), 3),
                     "p90_ms": round(values[min(len(values) - 1, round((len(values) - 1) * 0.9))], 3),
                     "max_ms": round(values[-1], 3)}
    return out

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__); sys.exit(2)
    print(json.dumps(intervals(sys.argv[1]), indent=2))
