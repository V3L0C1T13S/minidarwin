{ stdenv, sources, sdkHeaders, python3 }:
stdenv.mkDerivation {
  pname = "minidarwin-kernel-crypto-test";
  version = "1";
  src = sources.libressl;
  nativeBuildInputs = [ python3 ];
  dontConfigure = true;
  buildPhase = ''
    mkdir -p local-include compat
    cp include/compat/endian.h compat/
    ln -s ${sdkHeaders}/usr/include/corecrypto local-include/corecrypto
    $CC -O2 -DOPENSSL_NO_ASM -DHAVE_EXPLICIT_BZERO \
      -I${sources.xnu}/libkern -I${./support} -Ilocal-include -Icompat -Icrypto/hidden -Iinclude -Icrypto -Icrypto/arch/amd64 \
      -include ${./support/crypto-namespace.h} -include ${./support/digest-imports.h} \
      crypto/sha/sha1.c crypto/sha/sha256.c crypto/sha/sha512.c crypto/aes/aes_core.c \
      ${./support/kernel-digests.c} ${./support/kernel-drbg.c} ${./support/kernel-rng.c} ${./support/kernel-aes.c} ${./support/kernel-crypto-api.c} \
      ${./support/crypto-test.c} ${./support/aes-test.c} -o crypto-test
    ./crypto-test aes unused unused
    python3 ${./support/crypto-test.py} ${./support/drbg-vectors.json}
  '';
  installPhase = ''touch $out'';
}
