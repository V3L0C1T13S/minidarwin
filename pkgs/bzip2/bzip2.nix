# Apple's bzip2-47: libbz2 and its command-line tools.
{ lib, mkDarwinPackage, sources, toolchain, copyfile }:

let
  srcDir = "$PWD/bzip2";
  librarySources = [
    "blocksort.c" "bzlib.c" "compress.c" "crctable.c"
    "decompress.c" "huffman.c" "randtable.c"
  ];
  crcSource = if toolchain.targetArch == "aarch64"
    then "arm64/crc32vec.s"
    else "x86_64/crc32vec.s";
in

mkDarwinPackage {
  pname = "bzip2";
  version = lib.removePrefix "bzip2-" sources.bzip2.rev;
  src = sources.bzip2;
  inherit toolchain;
  passthru = {
    installName = "/usr/lib/libbz2.1.0.dylib";
    headers = builtins.placeholder "out";
  };

  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    md_compile "$PWD/obj/libbz2" "$CC" -O2 -D_FILE_OFFSET_BITS=64 \
      -- ${lib.concatMapStringsSep " " (f: "${srcDir}/${f}") librarySources} \
         "${srcDir}/${crcSource}"
    MD_COMPAT_VERSION=1.0 MD_CURRENT_VERSION=1.0.8 \
      md_dylib libbz2.1.0.dylib /usr/lib/libbz2.1.0.dylib obj/libbz2 \
        -Wl,-unexported_symbols_list,$PWD/unexports -lSystem
    ln -s libbz2.1.0.dylib libbz2.dylib

    md_compile "$PWD/obj/bzip2" "$CC" -O2 -D_FILE_OFFSET_BITS=64 \
      -- "$PWD/bzip2/bzip2.c"
    mkdir -p bin
    "$CC" -o "$PWD/bin/bzip2" "$PWD/obj/bzip2"/*.o \
      -L"$PWD" -lbz2 \
      -L${copyfile}/usr/lib -lcopyfile \
      -lSystem

    md_compile "$PWD/obj/bzip2recover" "$CC" -O2 -D_FILE_OFFSET_BITS=64 \
      -- "$PWD/bzip2/bzip2recover.c"
    "$CC" -o "$PWD/bin/bzip2recover" "$PWD/obj/bzip2recover"/*.o -lSystem
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 libbz2.1.0.dylib "$out/usr/lib/libbz2.1.0.dylib"
    ln -s libbz2.1.0.dylib "$out/usr/lib/libbz2.dylib"
    install -Dm644 bzip2/bzlib.h "$out/usr/include/bzlib.h"
    install -Dm755 bin/bzip2 "$out/usr/bin/bzip2"
    ln -s bzip2 "$out/usr/bin/bunzip2"
    ln -s bzip2 "$out/usr/bin/bzcat"
    install -Dm755 bin/bzip2recover "$out/usr/bin/bzip2recover"
    install -Dm644 bzip2/bzip2.1 "$out/usr/share/man/man1/bzip2.1"
    install -Dm644 bzip2/LICENSE "$out/usr/share/licenses/bzip2/LICENSE"

    md_verify_pure "$out/usr/lib/libbz2.1.0.dylib"
    md_verify_signed "$out/usr/lib/libbz2.1.0.dylib"
    md_verify_symbols "$out/usr/lib/libbz2.1.0.dylib" \
      _BZ2_bzCompressInit _BZ2_bzCompress _BZ2_bzDecompressInit \
      _BZ2_bzDecompress _BZ2_bzlibVersion
    md_verify_pure "$out/usr/bin/bzip2"
    md_verify_signed "$out/usr/bin/bzip2"
    md_verify_pure "$out/usr/bin/bzip2recover"
    md_verify_signed "$out/usr/bin/bzip2recover"
    runHook postInstall
  '';

  meta.description = "Apple's bzip2 compression library and utilities";
}
