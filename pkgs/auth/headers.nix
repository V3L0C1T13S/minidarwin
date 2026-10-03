# Build-private headers; no host SDK or authentication implementations.
{ runCommand, sources }:
runCommand "minidarwin-auth-headers" { } ''
  mkdir -p $out/security $out/bsm
  cp ${sources.OpenPAM}/openpam/include/security/*.h $out/security/
  cp ${sources.OpenBSM}/openbsm/bsm/*.h $out/bsm/
  cp ${./rootless.h} $out/rootless.h
''
