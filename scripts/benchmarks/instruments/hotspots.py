#!/usr/bin/env python3
"""Top main-thread frames from an xctrace Time Profiler recording (self and inclusive sample counts).

  hotspots.py <file.trace> [--thread "Main Thread"] [--top 30] [--filter Jit]
"""
import argparse, collections, subprocess
import xml.etree.ElementTree as ET

def main():
    p = argparse.ArgumentParser()
    p.add_argument("trace"); p.add_argument("--thread", default="Main Thread", help="'main' = the first sampled thread (the process main thread), or a substring of the thread label"); p.add_argument("--top", type=int, default=30)
    p.add_argument("--filter", default=None, help="only frames whose binary/name contains this")
    p.add_argument("--under", default=None, help="only samples whose stack contains a frame with this name (callees)")
    p.add_argument("--callers-of", default=None, help="only samples containing this frame; show its callers")
    a = p.parse_args()
    xml = subprocess.run(["xcrun", "xctrace", "export", "--input", a.trace, "--xpath",
                          '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                         capture_output=True, text=True, check=True).stdout
    root = ET.fromstring(xml)
    ids = {e.attrib["id"]: e for e in root.iter() if "id" in e.attrib}
    res = lambda e: ids.get(e.attrib["ref"], e) if "ref" in e.attrib else e
    self_counts, incl = collections.Counter(), collections.Counter()
    total = 0
    main_tid = None
    for row in root.iter("row"):
        thread = row.find("thread")
        if thread is None: continue
        thread = res(thread)
        tid = thread.find("tid")
        tid = res(tid).text if tid is not None else None
        if a.thread == "main":
            main_tid = main_tid or tid
            if tid != main_tid: continue
        elif a.thread not in thread.attrib.get("fmt", ""): continue
        bt = row.find("tagged-backtrace")
        if bt is None: bt = row.find("backtrace")
        if bt is None: continue
        bt = res(bt)
        frames = []
        for f in bt.iter("frame"):
            f = res(f)
            name = f.attrib.get("name", "?")
            binary = f.find("binary")
            bname = res(binary).attrib.get("name", "") if binary is not None else ""
            frames.append(f"{name}  [{bname}]")
        if not frames: continue
        if a.callers_of:
            hit = next((i for i, x in enumerate(frames) if a.callers_of in x), None)
            if hit is None: continue
            frames = frames[hit:]
        if a.under:
            hit = next((i for i, x in enumerate(frames) if a.under in x), None)
            if hit is None: continue
            frames = frames[:hit + 1]
        total += 1
        if a.filter:
            frames = [x for x in frames if a.filter in x] or frames[:1]
        self_counts[frames[0]] += 1
        for name in set(frames): incl[name] += 1
    print(f"{total} samples on '{a.thread}' (1 ms each)\n-- self --")
    for name, n in self_counts.most_common(a.top): print(f"{n:6d}  {name}")
    print("-- inclusive --")
    for name, n in incl.most_common(a.top): print(f"{n:6d}  {name}")

if __name__ == "__main__":
    main()
