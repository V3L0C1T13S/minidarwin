# Native known-answer and bounds tests for dyld's standalone hash interface.
{ stdenv, sources, sdkHeaders }:
stdenv.mkDerivation {
  pname = "minidarwin-dyld-digests-test";
  version = "1";
  src = sources.libressl;
  dontConfigure = true;
  buildPhase = ''
    mkdir -p local-include compat
    cp include/compat/endian.h compat/
    ln -s ${sdkHeaders}/usr/include/corecrypto local-include/corecrypto
    $CC -O2 -DOPENSSL_NO_ASM -DHAVE_EXPLICIT_BZERO \
      -Ilocal-include -Icompat -Icrypto/hidden -Iinclude -Icrypto -Icrypto/arch/amd64 \
      -include ${./runtime/digest-imports.h} \
      crypto/sha/sha1.c crypto/sha/sha256.c crypto/sha/sha512.c \
      ${./runtime/digests.c} ${./runtime/digests-test.c} -o digests-test
    ./digests-test
  '';
  installPhase = ''touch $out'';
}
