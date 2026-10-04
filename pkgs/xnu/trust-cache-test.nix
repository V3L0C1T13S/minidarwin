{ stdenv }:
stdenv.mkDerivation {
  pname = "minidarwin-trust-cache-test";
  version = "1";
  src = ./support;
  dontConfigure = true;
  buildPhase = ''
    $CC -std=c11 -O2 -Wall -Wextra -Werror -I. trust-cache.c trust-cache-signed.c trust-cache-test.c -o trust-cache-test
    ./trust-cache-test
  '';
  installPhase = ''
    touch $out
  '';
}
