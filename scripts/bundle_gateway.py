"""Stage a private CPython runtime and installed gateway dependencies for Windows."""

from importlib.metadata import distribution, distributions
import json
from pathlib import Path
import shutil
import struct
import sys
import sysconfig


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "client" / "build"
RUNTIME = BUILD / "gateway-runtime"


def main():
    if sys.platform != "win32" or struct.calcsize("P") != 8 or sys.version_info[:2] != (3, 12):
        raise SystemExit("The gateway requires a 64-bit Windows Python 3.12 build environment.")
    base = Path(sys.base_prefix)
    packages = Path(sysconfig.get_path("purelib"))
    distribution("akshare")
    installed = sorted((item.metadata["Name"], item.version) for item in distributions(path=[str(packages)]))
    runtime_signature = json.dumps([str(base), str(packages), sys.version, installed])
    stamp = RUNTIME / ".runtime.json"
    if not stamp.is_file() or stamp.read_text(encoding="utf-8") != runtime_signature:
        if RUNTIME.exists():
            if RUNTIME.resolve().parent != BUILD.resolve() or RUNTIME.resolve().name != "gateway-runtime":
                raise SystemExit("Unexpected gateway staging directory.")
            shutil.rmtree(RUNTIME)
        RUNTIME.mkdir(parents=True)
        for pattern in ("python.exe", "python*.dll", "vcruntime*.dll", "LICENSE.txt"):
            for source in base.glob(pattern):
                shutil.copy2(source, RUNTIME / source.name)
        shutil.copytree(base / "DLLs", RUNTIME / "DLLs", ignore=shutil.ignore_patterns("_tkinter.pyd", "tcl*.dll", "tk*.dll"))
        shutil.copytree(
            base / "Lib", RUNTIME / "Lib",
            ignore=shutil.ignore_patterns("site-packages", "test", "tests", "__pycache__", "idlelib", "tkinter", "turtledemo", "ensurepip"),
        )
        shutil.copytree(
            packages, RUNTIME / "site-packages",
            ignore=shutil.ignore_patterns("__pycache__", "pip", "pip-*.dist-info"),
        )
        (RUNTIME / "python312._pth").write_text(
            ".\nDLLs\nLib\nsite-packages\n", encoding="ascii",
        )
        stamp.write_text(runtime_signature, encoding="utf-8")
    shutil.copytree(
        ROOT / "gateway", RUNTIME / "gateway", dirs_exist_ok=True,
        ignore=shutil.ignore_patterns("__pycache__"),
    )
    print(f"Gateway staged in {RUNTIME}")


if __name__ == "__main__":
    main()
