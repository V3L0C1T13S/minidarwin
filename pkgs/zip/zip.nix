# Apple's zip-29: Info-ZIP's zip and unzip command-line utilities.
{ lib, gnumake, mkDarwinPackage, sources, toolchain }:

mkDarwinPackage {
  pname = "zip";
  version = lib.removePrefix "zip-" sources.zip.rev;
  src = sources.zip;
  inherit toolchain;
  nativeBuildInputs = [ gnumake ];

  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD

    mkdir -p obj/zip30 obj/unzip60
    # Match Apple's wrapper: cross-compiling cannot run zip's host feature
    # probes reliably, and can incorrectly enable its replacement memset.
    : > obj/zip30/flags
    make -C obj/zip30 -f "$PWD/zip/zip30/unix/Makefile" generic \
      SRCDIR="$PWD/zip/zip30" \
      CC="$CC" BIND="$CC" \
      LOCAL_ZIP="-DLARGE_FILE_SUPPORT -Wall -O2" \
      LFLAGS2=

    make -C obj/unzip60 -f "$PWD/unzip/unzip60/unix/Makefile" unix_make unzips \
      SRCDIR="$PWD/unzip/unzip60" \
      CC="$CC" LD="$CC" \
      CFLAGS="-O3 -Wall -DBSD -DLARGE_FILE_SUPPORT -DUNICODE_SUPPORT" \
      CF_NOOPT="-I$PWD/unzip/unzip60 -I${../compat} -Ibzip2 -DUNIX" \
      LF2="${../compat}/quarantine-stub.c" \
      SL2="${../compat}/quarantine-stub.c"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    for tool in zip zipcloak zipnote zipsplit; do
      install -Dm755 "obj/zip30/$tool" "$out/usr/bin/$tool"
    done
    for tool in unzip funzip unzipsfx; do
      install -Dm755 "obj/unzip60/$tool" "$out/usr/bin/$tool"
    done
    install -Dm755 unzip/unzip60/unix/zipgrep "$out/usr/bin/zipgrep"
    ln -s unzip "$out/usr/bin/zipinfo"

    for page in zip zipcloak zipnote zipsplit; do
      install -Dm644 "zip/zip30/man/$page.1" "$out/usr/share/man/man1/$page.1"
    done
    for page in funzip unzip unzipsfx zipgrep zipinfo; do
      install -Dm644 "unzip/unzip60/man/$page.1" "$out/usr/share/man/man1/$page.1"
    done
    install -Dm644 zip/zip30/LICENSE "$out/usr/share/licenses/zip/zip.txt"
    install -Dm644 unzip/unzip60/LICENSE "$out/usr/share/licenses/zip/unzip.txt"

    for tool in zip zipcloak zipnote zipsplit unzip funzip unzipsfx; do
      md_verify_pure "$out/usr/bin/$tool"
      md_verify_signed "$out/usr/bin/$tool"
    done
    runHook postInstall
  '';

  meta.description = "Apple's zip and unzip utilities";
}
