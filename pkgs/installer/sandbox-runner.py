#!@python@
"""mdpkg script runner for macOS hosts, confined by sandbox-exec.

    mdpkg-sandbox-runner SCRIPT WORKDIR PACKAGE TARGET STAGED_ROOT

The script runs under a fixed shell with PATH limited to a fixed tool set.
It may write only beneath STAGED_ROOT (and to /dev/null), may execute only
that shell and those tools, and has no network. It can read the host: this
confines writes, it does not emulate a MiniDarwin system. If the sandbox
cannot be set up, the script does not run.
"""
import os
from pathlib import Path
import subprocess
import sys

SHELL = "@shell@"
TOOLS = "@tools@"  # PATH-style list of bin directories
SHELLS = {"/bin/sh", "/bin/bash", "/usr/bin/env sh", "/usr/bin/env bash"}


def sbpl_string(value):
    """A double-quoted SBPL string literal."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def interpreter(script):
    first = script.read_bytes().split(b"\n", 1)[0]
    if not first.startswith(b"#!"):
        return "/bin/sh"
    return " ".join(first[2:].decode("utf-8", "replace").split()[:2])


def main():
    if len(sys.argv) != 6:
        raise ValueError("usage: SCRIPT WORKDIR PACKAGE TARGET STAGED_ROOT")
    script, workdir, package, target, root = sys.argv[1:]
    root = Path(root).resolve(strict=True)
    if root == Path("/") or root.is_relative_to("/nix/store"):
        raise ValueError(f"unsafe staged root: {root}")
    for path in (script, workdir, target):
        if not Path(path).resolve().is_relative_to(root):
            raise ValueError(f"{path} is outside the staged root")
    wanted = interpreter(Path(script))
    if wanted not in SHELLS:
        raise ValueError(f"unsupported script interpreter: {wanted}")

    shell = Path(SHELL).resolve(strict=True)
    tools = " ".join(f"(subpath {sbpl_string(str(Path(d).resolve(strict=True)))})"
                     for d in TOOLS.split(":"))
    profile = f"""(version 1)
(allow default)
(deny network*)
(deny file-write*)
(allow file-write* (subpath {sbpl_string(str(root))}) (literal "/dev/null"))
(deny process-exec)
(allow process-exec (literal {sbpl_string(str(shell))}) {tools})
"""
    env = {
        "PATH": TOOLS,
        "HOME": workdir,
        "TMPDIR": workdir,
        "LC_ALL": "C",
        **{k: os.environ[k] for k in ("COMMAND_LINE_INSTALL", "PACKAGE_PATH", "DSTVOLUME",
                                       "DSTROOT", "INSTALLER_TEMP") if k in os.environ},
    }
    result = subprocess.run(
        ["/usr/bin/sandbox-exec", "-p", profile, str(shell), script, package, target, str(root)],
        cwd=workdir, env=env, check=False)
    return result.returncode if result.returncode >= 0 else 128 - result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"mdpkg-sandbox-runner: {error}", file=sys.stderr)
        sys.exit(126)
