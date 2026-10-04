#!/usr/bin/env python3
"""Build the frontend's link inputs without linking a layout implementation."""
import json
from pathlib import Path
import shlex
import subprocess
import sys

build = Path("build")
commands = subprocess.check_output(["ninja", "-C", str(build), "-t", "commands", "clang"], text=True)
link = None
for line in commands.splitlines():
    tokens = shlex.split(line)
    if "-o" not in tokens:
        continue
    output = tokens[tokens.index("-o") + 1]
    if not output.startswith("bin/clang"):
        continue
    while tokens and tokens[0] in (":", "&&"):
        tokens.pop(0)
    if "&&" in tokens:
        tokens = tokens[:tokens.index("&&")]
    link = tokens
if link is None:
    raise SystemExit("cannot locate Clang's generated link command")
inputs = [arg for arg in link if not arg.startswith("-")
          and not Path(arg).is_absolute() and arg.endswith((".o", ".a"))]
if not inputs:
    raise SystemExit("Clang link command has no frontend inputs")
subprocess.run(["ninja", "-C", str(build), "-j", sys.argv[1], *inputs], check=True)
out = Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
for arg in inputs:
    dest = out / arg
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes((build / arg).read_bytes())
link = [str(out / arg) if arg in inputs else arg for arg in link]
# Link metadata must not retain CMake's random build directory.
link = [arg for arg in link if not arg.startswith((
    "-ffile-prefix-map=", "-Wl,-sectcreate,__TEXT,__info_plist,"))]
(out / "link.json").write_text(json.dumps(link))
