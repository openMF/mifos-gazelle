#!/usr/bin/env python3
"""
Render Gazelle values files for a given environment "profile".

This is intentionally simple (text-based transforms) because:
- PH-EE values include many JAVA_TOOL_OPTIONS blocks in arrays, which are hard to override via Helm values layering.
- We want a single flag (-p micro|std|perf) to scale common JVM heap flags without changing upstream charts.
"""

from __future__ import annotations

import argparse
import pathlib
import re


def _apply_profile_to_text(text: str, profile: str, kind: str) -> str:
    if profile == "std":
        return text

    # Common heap replacements seen in this repo values.
    # Note: We intentionally do not try to be "perfect"; we scale common demo defaults.
    if profile == "micro":
        repl = {
            "-Xmx1024m": "-Xmx512m",
            "-Xms1024m": "-Xms256m",
            "-Xmx512m": "-Xmx256m",
            "-Xms512m": "-Xms128m",
            "-Xmx256m": "-Xmx192m",
            "-Xms256m": "-Xms96m",
            "-Xmx128m": "-Xmx96m",
            "-Xms128m": "-Xms64m",
            "-Xmx96m": "-Xmx96m",
            "-Xms96m": "-Xms64m",
            "-Xmx64m": "-Xmx64m",
            "-Xms64m": "-Xms64m",
        }
        # SerialGC tends to behave better with tiny heaps.
        gc_from, gc_to = None, None
    elif profile == "perf":
        repl = {
            "-Xmx64m": "-Xmx128m",
            "-Xms64m": "-Xms128m",
            "-Xmx96m": "-Xmx192m",
            "-Xms96m": "-Xms192m",
            "-Xmx128m": "-Xmx256m",
            "-Xms128m": "-Xms256m",
            "-Xmx192m": "-Xmx384m",
            "-Xms192m": "-Xms384m",
            "-Xmx256m": "-Xmx512m",
            "-Xms256m": "-Xms512m",
            "-Xmx512m": "-Xmx1024m",
            "-Xms512m": "-Xms1024m",
        }
        # For perf, prefer G1GC over SerialGC (common for larger heaps).
        gc_from, gc_to = "-XX:+UseSerialGC", "-XX:+UseG1GC"
    else:
        raise ValueError(f"Unknown profile: {profile}")

    # Apply deterministic replacements first (string replace).
    for a, b in repl.items():
        text = text.replace(a, b)

    if gc_from and gc_to:
        text = text.replace(gc_from, gc_to)

    # Small infra-specific touch: keep elastic/kibana/node options stable unless explicitly present.
    # No-op for now; leaving kind hook for future.
    _ = kind

    # Normalize accidental double spaces after replacements in heap opts lines.
    text = re.sub(r"[ \t]+\n", "\n", text)
    return text


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", required=True, choices=["micro", "std", "perf"])
    ap.add_argument("--kind", required=True, choices=["ph", "infra"])
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out", dest="out", required=True)
    args = ap.parse_args()

    inp = pathlib.Path(args.inp)
    out = pathlib.Path(args.out)

    text = inp.read_text(encoding="utf-8")
    rendered = _apply_profile_to_text(text, args.profile, args.kind)

    # Ensure output dir exists
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

