#!/usr/bin/env python3
"""Link the cached upstream frontend with MiniDarwin's layout implementation."""
import json
from pathlib import Path
import subprocess
import sys

args = json.loads(Path(sys.argv[1]).read_text())
# CMake's optional macOS bundle metadata names its discarded build directory.
# The compiler is an ordinary CLI executable and requires no Info.plist.
args = [arg for arg in args if not arg.startswith('-Wl,-sectcreate,__TEXT,__info_plist,')]
args[args.index("-o") + 1] = "clang"
first_archive = next(i for i, arg in enumerate(args) if arg.endswith(".a"))
args.insert(first_archive, "layout.o")
subprocess.run(args, check=True)
