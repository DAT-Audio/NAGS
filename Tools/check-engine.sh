#!/bin/zsh
# The engine must build for Windows too: it may import only Foundation, Observation,
# the C atomics, and a platform's own libraries (Darwin, WinSDK, …) behind an `#if` — either
# `#if canImport(...)` just above the import, or `#if os(...)` around the whole file. Trailing
# comments on an import are fine. Run after changing the engine.
cd "${0:A:h}/.."
python3 - <<'PY'
import re, pathlib, sys
allowed = {"Foundation", "Observation", "NetworkAudioAtomics", "Crypto"}
platform = {"Darwin", "Glibc", "WinSDK", "ucrt", "os"}
bad = []
for f in sorted(pathlib.Path("Sources/NetworkAudioEngine").rglob("*.swift")):
    lines = f.read_text().split("\n")
    depth = 0                                    # inside any #if
    for n, raw in enumerate(lines, 1):
        line = raw.split("//")[0].strip()
        if line.startswith("#if"): depth += 1
        elif line.startswith("#endif"): depth = max(0, depth - 1)
        m = re.match(r"^(?:@_exported\s+)?import\s+(\w+)$", line)
        if not m: continue
        name = m.group(1)
        if name in allowed: continue
        if name in platform and depth > 0: continue
        bad.append(f"{f}:{n}: import {name}" + ("" if name in platform else " (not allowed in the engine)") + ("" if name not in platform else " (not behind #if)"))
if bad:
    print("The engine imports something Windows doesn't have:"); print("\n".join(bad)); sys.exit(1)
print("Engine imports: Foundation, Observation, atomics, and platform libraries behind #if only.")
PY
