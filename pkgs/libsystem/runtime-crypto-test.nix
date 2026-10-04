# Exercise entropy syscall chunking, failure clearing, and rejection sampling.
{ stdenv, sources, sdkHeaders }:
stdenv.mkDerivation {
  pname = "minidarwin-runtime-crypto-test";
  version = "1";
  src = sources.libressl;
  dontConfigure = true;
  buildPhase = ''
    mkdir -p local-include compat
    cp include/compat/endian.h compat/
    ln -s ${sdkHeaders}/usr/include/corecrypto local-include/corecrypto
    $CC -O2 -DOPENSSL_NO_ASM -DHAVE_EXPLICIT_BZERO \
      -Dgetentropy=md_test_getentropy \
      -Ilocal-include -Icompat -Icrypto/hidden -Iinclude -Icrypto -Icrypto/arch/amd64 \
      -include ${../dyld/runtime/digest-imports.h} \
      crypto/sha/sha1.c crypto/sha/sha256.c crypto/sha/sha512.c \
      ${../dyld/runtime/digests.c} ${./runtime-rng.c} ${./runtime-rng-test.c} -o rng-test
    ./rng-test
  '';
  installPhase = ''touch $out'';
}
