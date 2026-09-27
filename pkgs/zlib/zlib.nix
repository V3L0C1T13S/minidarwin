# Apple's zlib-100: libz.1.dylib and its public headers.
{ lib, mkDarwinPackage, sources, toolchain }:

let
  files = [
    "adler32.c" "compress.c" "crc32.c" "deflate.c" "gzclose.c"
    "gzlib.c" "gzread.c" "gzwrite.c" "infback.c" "inffast.c"
    "inflate.c" "inftrees.c" "trees.c" "uncompr.c" "zutil.c"
  ];
in

mkDarwinPackage {
  pname = "zlib";
  version = lib.removePrefix "zlib-" sources.zlib.rev;
  src = sources.zlib;
  inherit toolchain;

  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    md_compile "$PWD/obj" "$CC" -std=gnu11 -O2 -DUSE_MMAP \
      -- ${lib.concatMapStringsSep " " (f: "$PWD/zlib/${f}") files}
    MD_COMPAT_VERSION=1 MD_CURRENT_VERSION=1.2.12 \
      md_dylib libz.1.dylib /usr/lib/libz.1.dylib obj \
        -Wl,-exported_symbols_list,$PWD/libz.exp -lSystem
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 libz.1.dylib "$out/usr/lib/libz.1.dylib"
    # Match the compatibility names installed by Apple's Xcode project.
    for name in libz.dylib libz.1.1.3.dylib libz.1.2.5.dylib \
      libz.1.2.8.dylib libz.1.2.11.dylib libz.1.2.12.dylib; do
      ln -s libz.1.dylib "$out/usr/lib/$name"
    done
    install -Dm644 zlib/zlib.h "$out/usr/include/zlib.h"
    install -Dm644 zlib/zconf.h "$out/usr/include/zconf.h"
    install -Dm644 zlib.modulemap "$out/usr/include/zlib.modulemap"
    install -Dm644 zlib/zlib.3 "$out/usr/share/man/man3/zlib.3"
    mkdir -p "$out/usr/share/licenses/zlib"
    sed -n '/^Copyright notice:/,/madler@alumni.caltech.edu/p' zlib/README \
      > "$out/usr/share/licenses/zlib/LICENSE"

    md_verify_pure "$out/usr/lib/libz.1.dylib"
    md_verify_signed "$out/usr/lib/libz.1.dylib"
    md_verify_symbols "$out/usr/lib/libz.1.dylib" \
      _zlibVersion _deflate _inflate _inflateEnd _gzread
    runHook postInstall
  '';

  meta.description = "Apple's zlib compression library";
}
