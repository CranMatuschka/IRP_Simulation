"""Regenerate every thesis figure.

    cd IRP/Codes/IRP_Simulation/thesis_figures
    python3 make_all.py            # all figures
    python3 make_all.py ch07       # only generators whose name contains ch07

Each generator writes one PDF into IRP/Test/figures/generated/. Rebuild the
thesis afterwards with `latexmk -pdf main` in IRP/Test.
"""

from __future__ import annotations

import glob
import importlib
import os
import sys
import traceback

import thesisviz as tv


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    pattern = argv[1] if len(argv) > 1 else ""

    names = sorted(
        os.path.splitext(os.path.basename(p))[0]
        for p in glob.glob(os.path.join(here, "fig_*.py"))
        if pattern in os.path.basename(p)
    )
    if not names:
        print("no generators match " + repr(pattern))
        return 1

    print(f"writing into {tv.OUTDIR}")
    failed = []
    for name in names:
        print(name)
        try:
            module = importlib.import_module(name)
            module.main()
        except Exception:
            failed.append(name)
            traceback.print_exc()

    print(f"\n{len(names) - len(failed)} of {len(names)} generators succeeded")
    if failed:
        print("failed: " + ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
