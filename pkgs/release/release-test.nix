# Stage 7 check: the release tooling rejects what it should, and the real
# release verifies -- including after it is tampered with, which it must not.
{ runCommand, python3, rootfsRelease, mdrootfsScript }:

let
  r = rootfsRelease;
in
runCommand "minidarwin-release-test" { nativeBuildInputs = [ python3 ]; } ''
  set -euo pipefail
  mkdir scripts
  cp ${mdrootfsScript} scripts/mdrootfs.py
  cp ${../../scripts/test_mdrootfs.py} scripts/test_mdrootfs.py
  python3 scripts/test_mdrootfs.py -v

  md() { python3 scripts/mdrootfs.py "$@"; }
  md verify --spec ${r}/${r.spec} --manifest ${r}/${r.manifest} \
    --artifact ${r}/${r.artifact} --extract-to root

  # Self-healing starts from a report that names the damage; make sure it does.
  chmod u+w root/usr/lib
  lib=$(cd root/usr/lib && ls *.dylib | head -n 1)
  rm "root/usr/lib/$lib"
  if md verify --manifest ${r}/${r.manifest} --tree root > report.txt; then
    echo "release-test: a tree missing /usr/lib/$lib verified" >&2
    exit 1
  fi
  grep -q "missing    /usr/lib/$lib" report.txt

  touch $out
''
