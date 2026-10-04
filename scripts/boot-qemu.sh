#!/bin/sh
# Boot the full MiniDarwin disk (kernel collection + ext4 root with launchd)
# in QEMU. The serial console is this terminal; press Ctrl-C to stop QEMU.
#
# This is `qemuBoot`, not `qemuKernel`: qemuKernel's disk has no root
# partition, so XNU panics when it looks for one.
#
# `path:` makes the flake include files git does not track yet; with
# everything committed or `git add`ed, `nix run .#qemuBoot` is the same.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
exec nix run "path:$repo#qemuBoot" -- "$@"
