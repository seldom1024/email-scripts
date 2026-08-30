#!/usr/bin/env python3
"""Run the shared fake-Nacos lifecycle contract against the generated Sidecar registrar."""
from pathlib import Path
import runpy
import sys

if len(sys.argv) != 2:
    raise SystemExit(f"usage: {Path(sys.argv[0]).name} REGISTRAR_PATH")

root = Path(__file__).resolve().parents[1]
existing_test = root / "tests" / "test_nacos_registrar.py"
sys.argv = [str(existing_test), sys.argv[1]]
runpy.run_path(str(existing_test), run_name="__main__")
