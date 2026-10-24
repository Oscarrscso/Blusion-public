#!/usr/bin/env python3
"""Summarise an Instruments Time Profiler export (xctrace export, table time-profile).

    summarize-profile.py profile.xml [--thread SUBSTRING]

Prints, for the main thread (or the threads whose name contains SUBSTRING): the share of samples that each function is the leaf of
("self"), the share of samples with it anywhere on the stack ("inclusive"), and the app's own functions first seen from the top.
"""
import collections
import sys
import xml.etree.ElementTree as ET

APP_BINARIES = ("Blusion", "Features", "StremioKit", "PlayerKit", "Persistence", "FallbackPlayer")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 64
    path = sys.argv[1]
    wanted = "Main Thread"
    if "--thread" in sys.argv:
        wanted = sys.argv[sys.argv.index("--thread") + 1]

    frames: dict[str, tuple[str, str]] = {}      # id -> (symbol, binary)
    binaries: dict[str, str] = {}                # id -> binary name
    stacks: dict[str, list[str]] = {}            # id -> frame ids, leaf first
    threads: dict[str, str] = {}                 # id -> description
    weights = collections.Counter()
    self_time = collections.Counter()
    inclusive = collections.Counter()
    first_app = collections.Counter()
    total = 0.0

    def frame_of(element):
        ref = element.get("ref")
        if ref is not None:
            return ref
        frame_id = element.get("id")
        binary = element.find("binary")
        binary_name = ""
        if binary is not None:
            if binary.get("id") and binary.get("name"):
                binaries[binary.get("id")] = binary.get("name")
            binary_name = binary.get("name") or binaries.get(binary.get("ref"), "")
        frames[frame_id] = (element.get("name") or element.get("addr") or "?", binary_name)
        return frame_id

    for _, row in ET.iterparse(path, events=("end",)):
        if row.tag != "row":
            continue
        thread = row.find("thread")
        stack = next((row.find(tag) for tag in ("tagged-backtrace", "backtrace", "stack") if row.find(tag) is not None), None)
        weight = row.find("weight")
        if thread is None or stack is None:
            row.clear()
            continue
        if thread.get("id"):
            threads[thread.get("id")] = thread.get("fmt", "")
        description = threads.get(thread.get("ref") or thread.get("id"), thread.get("fmt", ""))
        ids = [frame_of(f) for f in stack.findall("frame")] if stack.get("ref") is None else stacks.get(stack.get("ref"), [])
        if stack.get("id"):
            stacks[stack.get("id")] = ids
        if wanted not in description:
            row.clear()
            continue
        try:
            milliseconds = float((weight.text or "1000000")) / 1_000_000 if weight is not None else 1.0
        except ValueError:
            milliseconds = 1.0
        total += milliseconds
        if ids:
            functions = [frames.get(frame_id, ("?", "")) for frame_id in ids]   # leaf first; counted by name, not by address
            self_time[functions[0]] += milliseconds
            for function in set(functions):
                inclusive[function] += milliseconds
            for function in functions:                  # the Blusion function nearest the leaf
                if function[1] in APP_BINARIES or function[1].startswith("Blusion"):
                    first_app[function] += milliseconds
                    break
        row.clear()

    if total == 0:
        print(f"no samples for a thread named '{wanted}'")
        return 1

    def show(title, counter, count=18):
        print(f"\n{title}")
        for (symbol, binary), ms in counter.most_common(count):
            print(f"  {100 * ms / total:5.1f}%  {symbol[:100]}  [{binary}]")

    print(f"{total:.0f} ms of '{wanted}' samples")
    show("Where the main thread is (leaf frame):", self_time)
    show("On the stack the most (inclusive):", inclusive, 28)
    show("Nearest Blusion function to the leaf:", first_app, 14)
    return 0


if __name__ == "__main__":
    sys.exit(main())
