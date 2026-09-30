# /usr/bin/mdpkg for the rootfs. Links only MiniDarwin's own libxml2, zlib and
# LibreSSL; no CoreFoundation, no Installer framework.
{ mkDarwinPackage, toolchain, libxml2, zlib, libressl }:

let
  sources = [ "main.c" "util.c" "xml.c" "xar.c" "cpio.c" "package.c" "install.c" "receipts.c" ];
in

mkDarwinPackage {
  pname = "mdpkg";
  version = "1.0.0";
  src = ./.;
  inherit toolchain;

  buildPhase = ''
    runHook preBuild
    $CC -std=c11 -O2 -Wall -Wextra -Werror \
      -I${libxml2}/usr/include/libxml2 -I${zlib}/usr/include \
      -I${libressl}/usr/local/libressl/include \
      ${builtins.concatStringsSep " " sources} -o mdpkg \
      -L${libxml2}/usr/lib -L${zlib}/usr/lib -L${libressl}/usr/lib \
      -lxml2 -lz -lcrypto
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 mdpkg $out/usr/bin/mdpkg
    install -Dm644 README.md $out/usr/share/doc/mdpkg/README.md
    deps=$($OTOOL -L $out/usr/bin/mdpkg | tail -n +2 | awk '{ print $1 }' | sort | tr '\n' ' ')
    expected=$(printf '%s\n' /usr/lib/libSystem.B.dylib \
      "$($OTOOL -D ${libxml2}/usr/lib/libxml2.dylib | tail -n 1)" \
      "$($OTOOL -D ${zlib}/usr/lib/libz.dylib | tail -n 1)" \
      "$($OTOOL -D ${libressl}/usr/lib/libcrypto.dylib | tail -n 1)" | sort | tr '\n' ' ')
    if [ "$deps" != "$expected" ]; then
      echo "mdpkg: unexpected load commands: $deps (want $expected)" >&2
      exit 1
    fi
    md_verify_pure $out/usr/bin/mdpkg
    md_verify_signed $out/usr/bin/mdpkg
    runHook postInstall
  '';

  meta.description = "Flat .pkg installer for offline MiniDarwin roots";
}
