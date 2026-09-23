# mdrootfs: manifests, specs and verification for rootfs releases, as a command.
# Host world. The script needs nothing but Python 3.8+, so it also runs as
# `python3 scripts/mdrootfs.py` on a machine without Nix.
{ writeShellScriptBin, python3, mdrootfsScript }:

writeShellScriptBin "mdrootfs" ''
  exec ${python3}/bin/python3 ${mdrootfsScript} "$@"
''
