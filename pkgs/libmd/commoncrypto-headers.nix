# <CommonCrypto/CommonDigest.h> from CommonCrypto's last release, for what
# includes it: libmd's own public headers, and sort (text_cmds). Only that
# header -- nothing includes the others -- and not into the SDK: libcommonCrypto
# is absent (absent-members.nix), so every consumer declares the CC_* functions
# it calls in its allowUndefined, labelled `commonCrypto`.
{ runCommand
, sources
}:

runCommand "commoncrypto-headers-${sources.CommonCrypto.rev}" { } ''
  install -Dm644 ${sources.CommonCrypto}/include/CommonDigest.h \
    $out/usr/include/CommonCrypto/CommonDigest.h
''
